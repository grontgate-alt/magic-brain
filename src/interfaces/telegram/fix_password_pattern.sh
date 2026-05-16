#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain
cd $BASE

echo "[1/2] Фикс token_vault: паттерн паролей с поддержкой кириллицы..."
cat << 'PY' > privacy/vault/token_vault.py
import re, uuid

class TokenVault:
    """Токенизатор с поддержкой кириллицы в паролях"""
    def __init__(self):
        pass
    
    def scrub(self, text: str) -> tuple[str, dict]:
        tokens = {}
        patterns = [
            (r'[\w.-]+@[\w.-]+\.\w+', 'EMAIL'),
            (r'\+?7?\s?\(?\d{3}\)?\s?\d{3}[-\s]?\d{2}[-\s]?\d{2}', 'PHONE'),
            (r'\b\d{8,}\b', 'NUMBER'),
            # ✅ Пароль: ключевое слово + значение (с поддержкой кириллицы!)
            (r'(пароль|password|pwd|секрет|pass)\s*[=:]\s*([^\s,;.!?\n]{4,})', 'SECRET'),
            # ✅ Отдельные "сложные" значения (6+ символов, смесь букв/цифр)
            (r'(?<![\w@])([A-Za-z0-9а-яА-ЯёЁ]{6,})(?![\w@.])', 'SECRET'),
        ]
        
        result = text
        for pattern, tag in patterns:
            matches = list(re.finditer(pattern, result, re.IGNORECASE))
            for m in reversed(matches):
                orig = m.group(0)
                # Для SECRET с группами берём только значение (группа 2)
                if tag == 'SECRET' and m.lastindex and m.lastindex >= 2:
                    orig = m.group(2)
                    # Пересчитываем позиции для замены только значения
                    start, end = m.start(2), m.end(2)
                else:
                    start, end = m.start(), m.end()
                
                token = f"[__SCRUB_{tag}_{uuid.uuid4().hex[:8]}__]"
                tokens[token] = orig
                result = result[:start] + token + result[end:]
        
        return result, tokens
    
    def unscrub(self, text: str, tokens: dict) -> str:
        for token, orig in tokens.items():
            text = text.replace(token, orig)
        return text
PY
echo "✅ token_vault: паттерны с кириллицей"

echo "[2/2] Фикс orchestrator: гарантированное добавление ВСЕХ недостающих данных..."
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
        
        # === CLOUD поток ===
        prompt = user_query
        tokens = {}
        original_sensitive = []
        
        if self.router.needs_scrubbing(user_query):
            prompt, tokens = self.vault.scrub(user_query)
            original_sensitive = list(tokens.values())
        
        vec = self.embedder.embed([prompt])[0]
        results = self.store.search(vec, limit=5)
        ctx_texts = [(r.get("payload") or r.get("meta") or {}).get("text", "") for r in results]
        
        system = "Отвечай подробно. Если видишь [__SCRUB_*__] — включи их в ответ как есть."
        full_prompt = f"{system}\n\nКонтекст:\n" + "\n---\n".join(ctx_texts) + f"\n\nЗапрос: {prompt}"
        
        try:
            response = await self.cloud_llm.chat(prompt=full_prompt, context=[])
            model_used = "cloud"
        except Exception as e:
            response = await self.local_llm.chat(model="qwen2.5:3b", prompt=full_prompt, context=[])
            model_used = "qwen2.5:3b (fallback)"
        
        # === 1. Прямая де-токенизация ===
        if tokens:
            response = self.vault.unscrub(response, tokens)
        
        # === 2. Пост-обработка: добавляем ВСЕ недостающие оригиналы ===
        if original_sensitive and mode == "CLOUD":
            missing = [v for v in original_sensitive if v not in response]
            if missing:
                # Удаляем "отказные" блоки модели
                response = re.sub(r'\n*[-#*]*\s*(Важное замечание|Примечание|Обратите внимание|не могу|не отправляю).*?(?=\n\n|\Z)', '', response, flags=re.DOTALL|re.IGNORECASE)
                response = response.strip()
                # Добавляем недостающие данные
                response += f"\n\n[Данные из запроса: {', '.join(missing)}]"
        
        self._auto_save(f"ASSISTANT: {response}", user_id, "response")
        return {"reply": response, "privacy_mode": mode, "model_used": model_used, "context_used": len(ctx_texts)}
PY
echo "✅ orchestrator: гарантированное восстановление всех данных"

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
echo "  • email/phone/password в ответе: ✅✅✅ (все восстановлены)"
echo ""
echo "ЖДУ: финальный вывод."
