#!/bin/bash
set -e
BASE=~/magic-brain

echo "[1/3] Фикс openrouter_client.py (проверка ключа + фолбэк на локальную модель)..."
cat << 'PY' > $BASE/privacy/local_llm/openrouter_client.py
import httpx, os, sys, re
from pathlib import Path
BASE = Path(__file__).parent.parent.parent
if str(BASE) not in sys.path:
    sys.path.insert(0, str(BASE))
from rag.router.privacy_router import PrivacyRouter

class OpenRouterClient:
    def __init__(self, api_key: str = None, router: PrivacyRouter = None):
        self.key = api_key or os.getenv("OPENROUTER_API_KEY", "").strip()
        self.router = router or PrivacyRouter()
        self.base = "https://openrouter.ai/api/v1"
    
    async def chat(self, model: str, prompt: str, context: list[str] = None, fallback_local: bool = True) -> str:
        # Если ключ пустой — фолбэк на заглушку или локальную модель
        if not self.key:
            if fallback_local:
                # Ленивый импорт, чтобы не грузить локальную модель если не нужно
                from .ollama_client import OllamaClient
                local = OllamaClient()
                return await local.chat(model="qwen2.5:3b", prompt=prompt, context=context)
            return "⚠️ OpenRouter ключ не настроен. Укажи OPENROUTER_API_KEY в .env"
        
        safe_prompt = self.router.scrub(prompt)
        safe_ctx = [self.router.scrub(c) for c in context] if context else []
        ctx = "\n\nКонтекст:\n" + "\n---\n".join(safe_ctx) if safe_ctx else ""
        
        try:
            async with httpx.AsyncClient(timeout=60) as c:
                r = await c.post(
                    f"{self.base}/chat/completions", 
                    headers={
                        "Authorization": f"Bearer {self.key}",
                        "HTTP-Referer": "http://localhost",
                        "X-Title": "MagicBrain"
                    },
                    json={"model": model, "messages": [{"role":"user","content": ctx + "\n\n" + safe_prompt}]}
                )
                r.raise_for_status()
                return r.json().get("choices",[{}])[0].get("message",{}).get("content","⚠️ Пустой ответ от OpenRouter")
        except httpx.HTTPStatusError as e:
            if e.response.status_code == 401:
                return "⚠️ Неверный OpenRouter ключ. Проверь .env"
            return f"⚠️ OpenRouter ошибка {e.response.status_code}: {e.response.text[:200]}"
        except Exception as e:
            if fallback_local:
                from .ollama_client import OllamaClient
                local = OllamaClient()
                return await local.chat(model="qwen2.5:3b", prompt=prompt, context=context)
            return f"⚠️ Ошибка соединения с облаком: {str(e)[:150]}"
PY

echo "[2/3] Фикс orchestrator.py (передаём ключ корректно)..."
cat << 'PY' > $BASE/agents/main/orchestrator.py
import os, sys
from pathlib import Path
BASE = Path(__file__).parent.parent.parent
if str(BASE) not in sys.path:
    sys.path.insert(0, str(BASE))

from rag.router.privacy_router import PrivacyRouter
from rag.embed.local_embedder import LocalEmbedder
from rag.store.qdrant_client import RAGStore
from privacy.local_llm.ollama_client import OllamaClient
from privacy.local_llm.openrouter_client import OpenRouterClient
from agents.critic.critic import Critic
from agents.prompt_opt.optimizer import PromptOptimizer

class MagicBrain:
    def __init__(self):
        self.router = PrivacyRouter()
        self.embedder = LocalEmbedder()
        self.store = RAGStore()
        self.local_llm = OllamaClient()
        # Передаём ключ явно, клиент сам проверит на пустоту
        self.cloud_llm = OpenRouterClient(api_key=os.getenv("OPENROUTER_API_KEY"), router=self.router)
        self.critic = Critic()
        self.opt = PromptOptimizer()
    
    async def process(self, user_query: str, user_id: int, task_type: str = "default") -> dict:
        mode = self.router.classify(user_query)
        query_vec = self.embedder.embed([user_query])[0]
        context = self.store.search(query_vec, limit=5, privacy_filter=None if mode=="CLOUD" else "HIGH")
        ctx_texts = [c["text"] for c in context]
        optimized = self.opt.optimize(user_query, task_type)
        
        if mode == "LOCAL":
            response = await self.local_llm.chat(model="qwen2.5:3b", prompt=optimized, context=ctx_texts)
        else:
            # Для публичных: пробуем облако, при ошибке ключа — фолбэк на локальную
            response = await self.cloud_llm.chat(
                model="meta-llama/llama-3.2-1b-instruct:free", 
                prompt=optimized, 
                context=ctx_texts,
                fallback_local=True  # ← ключевое: если ключ пустой, используем локальную модель
            )
        
        ok, issues = self.critic.validate(response)
        if not ok:
            return {"error": "Ответ заблокирован критиком", "issues": issues, "privacy_mode": mode}
        final = self.critic.refine(response, issues)
        return {"reply": final, "privacy_mode": mode, "context_used": len(ctx_texts), "issues": issues}
PY

echo "[3/3] Перезапуск API и тест..."
export PATH="$HOME/.local/bin:$PATH"
pkill -9 -f "uvicorn main:app" 2>/dev/null || true
sleep 3
cd $BASE/interfaces/api
nohup uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6

echo "Тесты:"
echo -n "🔹 /health: "
curl -sf http://127.0.0.1:8000/health && echo " ✅" || echo " ❌"

echo -n "🔹 /process (публичный, без ключа — фолбэк на локальную): "
curl -s -X POST http://127.0.0.1:8000/process \
  -H "Content-Type: application/json" \
  --max-time 90 \
  -d '{"user_id":1,"text":"рецепт борща","task_type":"default"}' | python3 -c "
import sys,json
d=json.load(sys.stdin)
if 'error' in d: print(f\"❌ {d['error'][:100]}\")
else: print(f\"✅ {d.get('reply','')[:100]}... [mode:{d.get('privacy_mode')}]\" )
" 2>/dev/null || echo "⚠️ Таймаут"

echo ""
echo "📝 Если ключ OpenRouter есть — обнови .env:"
echo "  OPENROUTER_API_KEY=sk-or-v1-..."
echo "  Затем: cd $BASE && sudo docker compose restart api-bridge"
echo ""
echo "ЖДУ: вывод теста. Если 'рецепт борща' вернул ответ — система полностью работает."
