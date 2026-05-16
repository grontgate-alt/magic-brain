#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain
cd $BASE

echo "[1/3] Фикс orchestrator: читаем .env в самом начале..."
cat << 'PY' > agents/main/orchestrator.py
import os, sys, uuid
from pathlib import Path

# === ЧИТАЕМ .env ПЕРЕД ВСЕМ ===
BASE_DIR = Path(__file__).parent.parent.parent
env_file = BASE_DIR / ".env"
if env_file.exists():
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            os.environ[k.strip()] = v.strip()

if str(BASE_DIR) not in sys.path: sys.path.insert(0, str(BASE_DIR))

from rag.router.privacy_router import PrivacyRouter
from rag.embed.local_embedder import LocalEmbedder
from rag.store.qdrant_client import RAGStore
from privacy.local_llm.ollama_client import OllamaClient
from privacy.local_llm.openrouter_client import OpenRouterClient
from privacy.vault.token_vault import TokenVault

class MagicBrain:
    def __init__(self):
        self.router = PrivacyRouter()
        self.embedder = LocalEmbedder()
        self.store = RAGStore()
        self.local_llm = OllamaClient()
        # Передаём ключ явно
        api_key = os.getenv("OPENROUTER_API_KEY", "")
        self.cloud_llm = OpenRouterClient(api_key=api_key, router=self.router)
        self.vault = TokenVault()

    def _auto_save(self, text: str, user_id: int, role: str):
        try:
            vec = self.embedder.embed([text])[0]
            payload = {"text": text, "user_id": user_id, "role": role, "privacy": "HIGH"}
            self.store.upsert([vec], [payload], [str(uuid.uuid4())])
        except Exception as e:
            print(f"⚠️ RAG save: {e}")

    async def process(self, user_query: str, user_id: int, task_type: str = "default") -> dict:
        self._auto_save(f"USER: {user_query}", user_id, "query")
        mode = self.router.classify(user_query)
        prompt = user_query
        if mode == "CLOUD":
            scrubbed, _ = self.vault.scrub(user_query)
            prompt = scrubbed
        vec = self.embedder.embed([prompt])[0]
        results = self.store.search(vec, limit=5)
        ctx_texts = [r.get("text", "") or r.get("meta", {}).get("text", "") for r in results]
        system = "Отвечай прямо. Используй контекст если релевантен. Без отказов."
        full_prompt = f"{system}\n\nКонтекст:\n" + "\n---\n".join(ctx_texts) + f"\n\nЗапрос: {prompt}"
        
        try:
            if mode == "LOCAL":
                response = await self.local_llm.chat(model="qwen2.5:3b", prompt=full_prompt, context=[])
                model_used = "qwen2.5:3b"
            else:
                response = await self.cloud_llm.chat(prompt=full_prompt, context=[])
                model_used = "cloud"
        except Exception as e:
            # Fallback на локальную модель при ошибке облака
            print(f"⚠️ Cloud error, fallback to local: {e}")
            response = await self.local_llm.chat(model="qwen2.5:3b", prompt=full_prompt, context=[])
            model_used = "qwen2.5:3b (fallback)"
        
        if mode == "CLOUD" and "[SCRUB_" in response:
            response = self.vault.unscrub(response)
        self._auto_save(f"ASSISTANT: {response}", user_id, "response")
        
        return {"reply": response, "privacy_mode": mode, "model_used": model_used, "context_used": len(ctx_texts)}
PY
echo "✅ orchestrator: явная загрузка .env + fallback"

echo "[2/3] Фикс openrouter_client: читаем ключ из аргумента или env..."
cat << 'PY' > privacy/local_llm/openrouter_client.py
import os, httpx, json

class OpenRouterClient:
    def __init__(self, api_key: str = None, router=None):
        self.api_key = api_key or os.getenv("OPENROUTER_API_KEY", "")
        self.router = router
        self.base_url = "https://openrouter.ai/api/v1"
        # Free-модели с ротацией
        self.models = [
            "qwen/qwen-2.5-7b-instruct:free",
            "meta-llama/llama-3.2-3b-instruct:free",
            "google/gemma-2-9b-it:free"
        ]
        self._idx = 0

    async def chat(self, prompt: str, context: list = None) -> str:
        if not self.api_key or len(self.api_key) < 20:
            return f"⚠️ OpenRouter ключ не задан. Проверь .env"
        
        ctx = "\n".join(context) if context else ""
        messages = [{"role": "system", "content": "Отвечай кратко и по делу."}]
        if ctx: messages.append({"role": "system", "content": f"Контекст: {ctx}"})
        messages.append({"role": "user", "content": prompt})
        
        # Пробуем модели по очереди при 429/500
        for attempt in range(len(self.models)):
            model = self.models[self._idx % len(self.models)]
            self._idx += 1
            try:
                async with httpx.AsyncClient(timeout=45) as c:
                    r = await c.post(
                        f"{self.base_url}/chat/completions",
                        headers={
                            "Authorization": f"Bearer {self.api_key}",
                            "HTTP-Referer": "http://localhost",
                            "X-Title": "MagicBrain",
                            "Content-Type": "application/json"
                        },
                        json={"model": model, "messages": messages, "max_tokens": 1024}
                    )
                    if r.status_code == 200:
                        d = r.json()
                        return d.get("choices",[{}])[0].get("message",{}).get("content","").strip()
                    elif r.status_code in (429, 500, 503):
                        continue  # пробуем следующую модель
                    else:
                        return f"⚠️ OpenRouter {r.status_code}: {r.text[:100]}"
            except Exception as e:
                continue
        return "⚠️ Не удалось получить ответ от облака (все модели недоступны)"
PY
echo "✅ openrouter_client: ротация моделей + обработка ошибок"

echo "[3/3] Перезапуск API..."
pkill -f uvicorn 2>/dev/null || true
sleep 3
set -a; source $BASE/.env; set +a
cd $BASE/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health && echo "✅ API UP" || { echo "❌ API DOWN"; tail -10 /tmp/api.log; }

echo ""
echo "🧪 Тест облака (напиши боту):"
echo "  • 'привет' → должен ответить с [☁️...] или [🔐...]"
echo "  • Если облако не отвечает → автоматический fallback на локальную модель"
echo ""
echo "Проверь логи: tail -20 /tmp/api.log"
echo "ЖДУ: результат."
