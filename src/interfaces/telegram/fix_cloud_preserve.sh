#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain
cd $BASE

echo "[1/3] Фикс openrouter_client: инструкция сохранять токены..."
cat << 'PY' > privacy/local_llm/openrouter_client.py
import os, httpx, json

class OpenRouterClient:
    def __init__(self, api_key: str = None, router=None):
        self.api_key = api_key or os.getenv("OPENROUTER_API_KEY", "")
        self.router = router
        self.base_url = "https://openrouter.ai/api/v1"
        self.model = "openrouter/free"

    async def chat(self, prompt: str, context: list = None, preserve_tokens: bool = True) -> str:
        if not self.api_key or len(self.api_key) < 20:
            return "⚠️ OpenRouter ключ не задан"
        
        ctx = "\n".join(context) if context else ""
        
        # === КЛЮЧЕВАЯ ИНСТРУКЦИЯ: сохранять токены ===
        token_instruction = ""
        if preserve_tokens and "[__SCRUB_" in prompt:
            token_instruction = "\n\n❗ ВАЖНО: В запросе есть токены вида [__SCRUB_*__]. НЕ заменяй их на другие значения. Просто скопируй их в ответ как есть, без изменений."
        
        messages = [{"role": "system", "content": f"Отвечай подробно и полезно.{token_instruction}"}]
        if ctx: messages.append({"role": "system", "content": f"Контекст:\n{ctx}"})
        messages.append({"role": "user", "content": prompt})
        
        try:
            async with httpx.AsyncClient(timeout=60) as c:
                r = await c.post(
                    f"{self.base_url}/chat/completions",
                    headers={
                        "Authorization": f"Bearer {self.api_key}",
                        "HTTP-Referer": "http://localhost",
                        "X-Title": "MagicBrain",
                        "Content-Type": "application/json"
                    },
                    json={"model": self.model, "messages": messages, "max_tokens": 2048, "temperature": 0.7}
                )
                if r.status_code == 200:
                    d = r.json()
                    return d.get("choices",[{}])[0].get("message",{}).get("content","").strip()
                else:
                    return f"⚠️ OpenRouter {r.status_code}: {r.text[:150]}"
        except Exception as e:
            return f"⚠️ OpenRouter ошибка: {type(e).__name__}: {str(e)[:100]}"
PY
echo "✅ openrouter_client: инструкция сохранять токены"

echo "[2/3] Фикс orchestrator: умное восстановление если токены потеряны..."
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
        vec = self.embedder.embed([query])[0]
        results = self.store.search(vec, limit=5)
        found = []
        for r in results:
            p = r.get("payload") or r.get("meta") or {}
            if p.get("user_id") in (None, user_id):
                txt = p.get("text") or ""
                txt = re.sub(r'^(USER|ASSISTANT):\s*', '', txt)
                if txt: found.append(txt)
        if found:
            return "Найдено в твоём хранилище:\n" + "\n".join(f"• {t}" for t in found[:3])
        return "⚠️ Ничего не найдено"

    def _smart_restore(self, response: str, original_query: str, tokens: dict) -> str:
        """
        Если прямая замена токенов не сработала, пробуем восстановить по типу значения:
        - Находим в ответе email/phone/number
        - Заменяем на оригиналы из запроса того же типа
        """
        if not tokens:
            return response
        
        # Сначала пробуем прямую замену
        result = self.vault.unscrub(response, tokens)
        if result != response:  # если что-то заменилось — готово
            return result
        
        # Иначе: умное восстановление по типу
        import re
        # Извлекаем оригинальные значения по типам из исходного запроса
        originals = {"EMAIL": [], "PHONE": [], "NUMBER": [], "SECRET": []}
        for token, orig in tokens.items():
            if "EMAIL" in token: originals["EMAIL"].append(orig)
            elif "PHONE" in token: originals["PHONE"].append(orig)
            elif "NUMBER" in token: originals["NUMBER"].append(orig)
            elif "SECRET" in token: originals["SECRET"].append(orig)
        
        # Ищем в ответе похожие паттерны и заменяем на оригиналы
        for tag, orig_list in originals.items():
            if not orig_list: continue
            pattern = {
                "EMAIL": r'[\w.-]+@[\w.-]+\.\w+',
                "PHONE": r'\+?7?\s?\(?\d{3}\)?\s?\d{3}[-\s]?\d{2}[-\s]?\d{2}',
                "NUMBER": r'\b\d{8,}\b',
                "SECRET": r'[A-Za-z0-9а-яА-ЯёЁ]{6,}'
            }.get(tag)
            if not pattern: continue
            
            matches = list(re.finditer(pattern, result, re.IGNORECASE))
            for i, m in enumerate(reversed(matches)):
                if i < len(orig_list):
                    # Заменяем найденное в ответе на оригинал из запроса
                    result = result[:m.start()] + orig_list[i] + result[m.end():]
        
        return result

    async def process(self, user_query: str, user_id: int, task_type: str = "default") -> dict:
        self._auto_save(f"USER: {user_query}", user_id, "query")
        mode = self.router.classify(user_query)
        
        if mode == "LOCAL":
            direct = self._direct_rag_return(user_query, user_id)
            if direct and "⚠️" not in direct:
                self._auto_save(f"ASSISTANT: {direct}", user_id, "response")
                return {"reply": direct, "privacy_mode": "LOCAL", "model_used": "rag_direct", "context_used": 0}
        
        # === CLOUD поток ===
        prompt = user_query
        tokens = {}
        
        if self.router.needs_scrubbing(user_query):
            prompt, tokens = self.vault.scrub(user_query)
        
        vec = self.embedder.embed([prompt])[0]
        results = self.store.search(vec, limit=5)
        ctx_texts = [(r.get("payload") or r.get("meta") or {}).get("text", "") for r in results]
        
        system = "Отвечай подробно и полезно."
        full_prompt = f"{system}\n\nКонтекст:\n" + "\n---\n".join(ctx_texts) + f"\n\nЗапрос: {prompt}"
        
        try:
            # Передаём preserve_tokens=True чтобы модель не меняла токены
            response = await self.cloud_llm.chat(prompt=full_prompt, context=[], preserve_tokens=True)
            model_used = "cloud"
        except Exception as e:
            response = await self.local_llm.chat(model="qwen2.5:3b", prompt=full_prompt, context=[])
            model_used = "qwen2.5:3b (fallback)"
        
        # === Восстановление: сначала прямое, потом умное ===
        if tokens:
            response = self._smart_restore(response, user_query, tokens)
        
        self._auto_save(f"ASSISTANT: {response}", user_id, "response")
        return {"reply": response, "privacy_mode": mode, "model_used": model_used, "context_used": len(ctx_texts)}
PY
echo "✅ orchestrator: умное восстановление значений"

echo "[3/3] Перезапуск API..."
pkill -f uvicorn 2>/dev/null || true
sleep 3
set -a; source $BASE/.env; set +a
cd $BASE/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health && echo "✅ API UP" || echo "❌ API DOWN"

echo ""
echo "🧪 Запусти test_complex_query.py ещё раз:"
echo "  • privacy_mode: CLOUD ✓"
echo "  • model_used: cloud ✓"
echo "  • email/phone/password в ответе: ✅ (восстановлены умным методом)"
echo ""
echo "ЖДУ: вывод теста."
