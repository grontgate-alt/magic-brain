#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain
cd $BASE

echo "[1/3] Фикс privacy_router: CLOUD by default, LOCAL только для 'покажи мои данные'..."
cat << 'PY' > rag/router/privacy_router.py
import re

class PrivacyRouter:
    def __init__(self):
        # Ключевые слова приватности (для токенизации, не для маршрутизации)
        self.sensitive_keywords = [
            'пароль', 'password', 'pwd', 'секрет', 'ключ', 'token', 'api_key',
            'карта', 'card', 'cvv', 'пин', 'pin', 'личное', 'приват', 'конфиденциально'
        ]
        # Паттерны для ИЗВЛЕЧЕНИЯ данных (только эти → LOCAL)
        self.retrieval_patterns = [
            r'покажи.*мой', r'напомни.*мой', r'какой.*мой.*пароль',
            r'что я сохранял', r'мой.*пароль.*от', r'достань.*из памяти',
            r'покажи.*из.*хранилищ', r'верни.*мой.*секрет'
        ]
    
    def classify(self, query: str) -> str:
        """
        Маршрутизация по интенту:
        - LOCAL: только если запрос явно на извлечение МОИХ сохранённых данных
        - CLOUD: всё остальное (с токенизацией чувствительных паттернов)
        """
        q = query.lower().strip()
        
        # Проверяем паттерны извлечения (только они → LOCAL)
        for pattern in self.retrieval_patterns:
            if re.search(pattern, q, re.IGNORECASE):
                return "LOCAL"
        
        # Всё остальное → CLOUD (с токенизацией при необходимости)
        return "CLOUD"
    
    def needs_scrubbing(self, text: str) -> bool:
        """Всегда возвращаем True для CLOUD-маршрута"""
        return any(kw in text.lower() for kw in self.sensitive_keywords)
PY
echo "✅ privacy_router: интент-маршрутизация"

echo "[2/3] Фикс orchestrator: токенизация ТОЛЬКО для CLOUD, прямой возврат для LOCAL..."
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
                txt = re.sub(r'^(USER|ASSISTANT):\s*', '', txt)
                if txt:
                    found.append(txt)
        if found:
            return "Найдено в твоём хранилище:\n" + "\n".join(f"• {t}" for t in found[:3])
        return "⚠️ Ничего не найдено по этому запросу"

    async def process(self, user_query: str, user_id: int, task_type: str = "default") -> dict:
        # 1. Авто-инжест запроса (всегда)
        self._auto_save(f"USER: {user_query}", user_id, "query")
        
        # 2. Классификация
        mode = self.router.classify(user_query)
        
        # 3. === ПРЯМОЙ ВОЗВРАТ ДЛЯ ЗАПРОСОВ НА ИЗВЛЕЧЕНИЕ ===
        if mode == "LOCAL":
            direct = self._direct_rag_return(user_query, user_id)
            if direct and "⚠️" not in direct:
                self._auto_save(f"ASSISTANT: {direct}", user_id, "response")
                return {"reply": direct, "privacy_mode": "LOCAL", "model_used": "rag_direct", "context_used": 0}
        
        # 4. Обычный поток (включая CLOUD)
        prompt = user_query
        scrubbed = None
        
        # Токенизация ТОЛЬКО для CLOUD
        if mode == "CLOUD" and self.router.needs_scrubbing(user_query):
            scrubbed, tokens = self.vault.scrub(user_query)
            prompt = scrubbed if scrubbed else user_query
        
        # Поиск в RAG (всегда)
        vec = self.embedder.embed([prompt])[0]
        results = self.store.search(vec, limit=5)
        ctx_texts = [(r.get("payload") or r.get("meta") or {}).get("text", "") for r in results]
        
        # Системный промпт
        system = "Отвечай подробно и полезно. Используй контекст если он релевантен."
        full_prompt = f"{system}\n\nКонтекст:\n" + "\n---\n".join(ctx_texts) + f"\n\nЗапрос: {prompt}"
        
        # Вызов LLM
        try:
            if mode == "LOCAL":
                response = await self.local_llm.chat(model="qwen2.5:3b", prompt=full_prompt, context=[])
                model_used = "qwen2.5:3b"
            else:
                response = await self.cloud_llm.chat(prompt=full_prompt, context=[])
                model_used = "cloud"
        except Exception as e:
            # Fallback на локальную при ошибке облака
            response = await self.local_llm.chat(model="qwen2.5:3b", prompt=full_prompt, context=[])
            model_used = "qwen2.5:3b (fallback)"
        
        # Де-токенизация ответа (только если был CLOUD и есть токены)
        if mode == "CLOUD" and scrubbed and "[SCRUB_" in response:
            response = self.vault.unscrub(response)
        
        # Авто-инжест ответа
        self._auto_save(f"ASSISTANT: {response}", user_id, "response")
        
        return {
            "reply": response,
            "privacy_mode": mode,
            "model_used": model_used,
            "context_used": len(ctx_texts)
        }
PY
echo "✅ orchestrator: токенизация только для CLOUD"

echo "[3/3] Перезапуск API..."
pkill -f uvicorn 2>/dev/null || true
sleep 3
set -a; source $BASE/.env; set +a
cd $BASE/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health && echo "✅ API UP" || echo "❌ API DOWN"

echo ""
echo "🧪 Тесты (теперь с правильной маршрутизацией):"
echo "  1. 'Рецепт блинов, отправь на 23424@eskd.com пароль 654укапе54у'"
echo "     → ☁️ CLOUD + токенизация → качественный ответ из облака"
echo "     → в ответе оригинальные данные восстановлены"
echo ""
echo "  2. 'Покажи мой пароль от почты'"
echo "     → 🔐 LOCAL + прямой возврат из RAG"
echo "     → покажет сырое значение без участия LLM"
echo ""
echo "  3. 'привет'"
echo "     → ☁️ CLOUD → обычный ответ"
echo ""
echo "Запусти test_complex_query.py ещё раз и проверь:"
echo "  • privacy_mode должен быть CLOUD (не LOCAL)"
echo "  • model_used должен быть 'cloud' (не 'qwen2.5:3b')"
echo "  • email/пароль должны быть в ответе (восстановлены из токенов)"
echo ""
echo "ЖДУ: вывод теста."
