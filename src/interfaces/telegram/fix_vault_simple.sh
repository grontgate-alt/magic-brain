#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain
cd $BASE

echo "[1/3] Простой TokenVault: токены хранятся в памяти запроса..."
cat << 'PY' > privacy/vault/token_vault.py
import re, uuid

class TokenVault:
    """Простой токенизатор: хранит маппинг только в пределах одного запроса"""
    def __init__(self):
        pass  # никаких глобальных хранилищ
    
    def scrub(self, text: str) -> tuple[str, dict]:
        """Заменяет чувствительные паттерны на токены, возвращает (текст, {токен: оригинал})"""
        tokens = {}
        patterns = [
            (r'[\w.-]+@[\w.-]+\.\w+', 'EMAIL'),
            (r'\+?7?\s?\(?\d{3}\)?\s?\d{3}[-\s]?\d{2}[-\s]?\d{2}', 'PHONE'),
            (r'\b\d{10,}\b', 'NUMBER'),
            (r'(пароль|password|pwd|секрет)\s*[=:]\s*(\S+)', 'SECRET'),
        ]
        
        result = text
        for pattern, tag in patterns:
            matches = list(re.finditer(pattern, result, re.IGNORECASE))
            for m in reversed(matches):  # с конца, чтобы не сбить индексы
                orig = m.group(0)
                token = f"[__SCRUB_{tag}_{uuid.uuid4().hex[:8]}__]"
                tokens[token] = orig
                result = result[:m.start()] + token + result[m.end():]
        
        return result, tokens
    
    def unscrub(self, text: str, tokens: dict) -> str:
        """Восстанавливает оригиналы по токенам"""
        for token, orig in tokens.items():
            text = text.replace(token, orig)
        return text
PY
echo "✅ TokenVault: простой per-request маппинг"

echo "[2/3] Фикс orchestrator: передаём tokens между scrub/unscrub..."
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

    async def process(self, user_query: str, user_id: int, task_type: str = "default") -> dict:
        self._auto_save(f"USER: {user_query}", user_id, "query")
        mode = self.router.classify(user_query)
        
        if mode == "LOCAL":
            direct = self._direct_rag_return(user_query, user_id)
            if direct and "⚠️" not in direct:
                self._auto_save(f"ASSISTANT: {direct}", user_id, "response")
                return {"reply": direct, "privacy_mode": "LOCAL", "model_used": "rag_direct", "context_used": 0}
        
        # === CLOUD поток с токенизацией ===
        prompt = user_query
        tokens = {}  # маппинг токенов для этого запроса
        
        if self.router.needs_scrubbing(user_query):
            prompt, tokens = self.vault.scrub(user_query)
        
        vec = self.embedder.embed([prompt])[0]
        results = self.store.search(vec, limit=5)
        ctx_texts = [(r.get("payload") or r.get("meta") or {}).get("text", "") for r in results]
        
        system = "Отвечай подробно и полезно. Используй контекст если релевантен."
        full_prompt = f"{system}\n\nКонтекст:\n" + "\n---\n".join(ctx_texts) + f"\n\nЗапрос: {prompt}"
        
        try:
            response = await self.cloud_llm.chat(prompt=full_prompt, context=[])
            model_used = "cloud"
        except Exception as e:
            response = await self.local_llm.chat(model="qwen2.5:3b", prompt=full_prompt, context=[])
            model_used = "qwen2.5:3b (fallback)"
        
        # === Де-токенизация: восстанавливаем оригиналы ===
        if tokens:
            response = self.vault.unscrub(response, tokens)
        
        self._auto_save(f"ASSISTANT: {response}", user_id, "response")
        return {"reply": response, "privacy_mode": mode, "model_used": model_used, "context_used": len(ctx_texts)}
PY
echo "✅ orchestrator: tokens передаются между scrub/unscrub"

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
echo "  • email/phone/password в ответе: ✅ (восстановлены)"
echo ""
echo "ЖДУ: вывод теста."
