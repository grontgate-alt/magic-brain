#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain
cd $BASE

echo "[1/2] Orchestrator: прямой возврат из RAG для 'покажи/напомни/мой пароль'..."
cat << 'PY' > agents/main/orchestrator.py
import os, sys, uuid, re
from pathlib import Path
BASE_DIR = Path(__file__).parent.parent.parent
env_file = BASE_DIR / ".env"
if env_file.exists():
    for ln in env_file.read_text().splitlines():
        if "=" in ln and not ln.strip().startswith("#"):
            k,v = ln.split("=",1); os.environ[k.strip()] = v.strip()
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
        self.cloud_llm = OpenRouterClient(api_key=os.getenv("OPENROUTER_API_KEY"), router=self.router)
        self.vault = TokenVault()

    def _auto_save(self, text: str, user_id: int, role: str):
        try:
            vec = self.embedder.embed([text])[0]
            payload = {"text": text, "user_id": user_id, "role": role, "privacy": "HIGH"}
            self.store.upsert([vec], [payload], [str(uuid.uuid4())])
        except Exception as e:
            print(f"⚠️ RAG save: {e}")

    def _direct_rag_return(self, query: str, user_id: int) -> str:
        """Прямой поиск и возврат сырых данных из RAG, без LLM"""
        vec = self.embedder.embed([query])[0]
        results = self.store.search(vec, limit=5)
        found = []
        for r in results:
            p = r.get("payload") or r.get("meta") or {}
            if p.get("user_id") in (None, user_id):
                txt = p.get("text") or ""
                # Убираем префиксы USER:/ASSISTANT: если есть
                txt = re.sub(r'^(USER|ASSISTANT):\s*', '', txt)
                if txt and query.lower() in txt.lower():
                    found.append(txt)
        if found:
            return "Найдено:\n" + "\n".join(f"• {t}" for t in found[:3])
        return "⚠️ Ничего не найдено в твоём хранилище"

    async def process(self, user_query: str, user_id: int, task_type: str = "default") -> dict:
        # 1. Авто-инжест запроса
        self._auto_save(f"USER: {user_query}", user_id, "query")
        
        # 2. === ПРЯМОЙ ВОЗВРАТ ИЗ RAG ДЛЯ ЗАПРОСОВ НА "ПОКАЗ" ===
        q = user_query.strip().lower()
        if any(kw in q for kw in ["покажи", "напомни", "мой пароль", "что я сохранял", "мой.*пароль"]):
            direct = self._direct_rag_return(user_query, user_id)
            if direct and "⚠️" not in direct:
                self._auto_save(f"ASSISTANT: {direct}", user_id, "response")
                return {"reply": direct, "privacy_mode": "LOCAL", "model_used": "rag_direct", "context_used": 0}
        
        # 3. Обычный поток
        mode = self.router.classify(user_query)
        prompt = user_query
        if mode == "CLOUD":
            scrubbed, _ = self.vault.scrub(user_query)
            prompt = scrubbed
        
        vec = self.embedder.embed([prompt])[0]
        results = self.store.search(vec, limit=5)
        ctx_texts = [(r.get("payload") or r.get("meta") or {}).get("text", "") for r in results]
        
        system = "Отвечай прямо. Используй контекст если релевантен."
        full_prompt = f"{system}\n\nКонтекст:\n" + "\n---\n".join(ctx_texts) + f"\n\nЗапрос: {prompt}"
        
        try:
            if mode == "LOCAL":
                response = await self.local_llm.chat(model="qwen2.5:3b", prompt=full_prompt, context=[])
                model_used = "qwen2.5:3b"
            else:
                response = await self.cloud_llm.chat(prompt=full_prompt, context=[])
                model_used = "cloud"
        except Exception as e:
            response = await self.local_llm.chat(model="qwen2.5:3b", prompt=full_prompt, context=[])
            model_used = "qwen2.5:3b (fallback)"
        
        if mode == "CLOUD" and "[SCRUB_" in response:
            response = self.vault.unscrub(response)
        
        self._auto_save(f"ASSISTANT: {response}", user_id, "response")
        return {"reply": response, "privacy_mode": mode, "model_used": model_used, "context_used": len(ctx_texts)}
PY
echo "✅ Orchestrator: прямой возврат из RAG"

echo "[2/2] Перезапуск API..."
pkill -f uvicorn 2>/dev/null || true
sleep 3
set -a; source $BASE/.env; set +a
cd $BASE/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health && echo "✅ API UP" || echo "❌ API DOWN"

echo ""
echo "🧪 Тест (напиши боту):"
echo "  1. 'Мой пароль от почты = SuperSecret123' → сохранится"
echo "  2. 'Покажи мой пароль от почты' → должно показать: • Мой пароль от почты = SuperSecret123"
echo "  3. 'привет' → обычный ответ от облака"
echo ""
echo "ЖДУ: результат."
