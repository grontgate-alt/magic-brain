#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain
cd $BASE

echo "[1/6] Полная очистка кэша и процессов..."
pkill -9 -f "uvicorn\|python3.*bot\|python3.*main" 2>/dev/null || true
sleep 3
find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
echo "✅ Процессы убиты, .pyc очищены"

echo "[2/6] Конфиг роутера (явные бесплатные модели OpenRouter)..."
cat << 'YAML' > config/openrouter.yaml
openrouter:
  models:
    - "qwen/qwen-2.5-7b-instruct:free"
    - "meta-llama/llama-3.3-70b-instruct:free"
    - "deepseek/deepseek-chat:free"
  timeout: 45
  fallback_local: true
YAML

echo "[3/6] Обновление openrouter_client.py..."
cat << 'PY' > privacy/local_llm/openrouter_client.py
import httpx, os, sys, yaml, random
from pathlib import Path
BASE = Path(__file__).parent.parent.parent
if str(BASE) not in sys.path: sys.path.insert(0, str(BASE))
from rag.router.privacy_router import PrivacyRouter

class OpenRouterClient:
    def __init__(self, api_key: str = None, router: PrivacyRouter = None, config_path: str = "config/openrouter.yaml"):
        self.key = api_key or os.getenv("OPENROUTER_API_KEY", "").strip()
        self.router = router or PrivacyRouter()
        self.base = "https://openrouter.ai/api/v1"
        
        cfg_path = Path(BASE / config_path if not Path(config_path).is_absolute() else config_path)
        cfg_data = yaml.safe_load(cfg_path.read_text()) if cfg_path.exists() else {}
        self.models = cfg_data.get("openrouter", {}).get("models", [
            "qwen/qwen-2.5-7b-instruct:free",
            "meta-llama/llama-3.3-70b-instruct:free"
        ])
        self.timeout = cfg_data.get("openrouter", {}).get("timeout", 45)
        self.fallback = cfg_data.get("openrouter", {}).get("fallback_local", True)
    
    async def chat(self, prompt: str, context: list[str] = None) -> str:
        if not self.key:
            return await self._fallback(prompt, context)
        
        safe_prompt = self.router.scrub(prompt)
        safe_ctx = [self.router.scrub(c) for c in (context or [])]
        ctx = "\n\nКонтекст:\n" + "\n---\n".join(safe_ctx) if safe_ctx else ""
        
        model = random.choice(self.models)
        payload = {"model": model, "messages": [{"role": "user", "content": ctx + "\n\n" + safe_prompt}]}
        
        try:
            async with httpx.AsyncClient(timeout=self.timeout) as c:
                r = await c.post(f"{self.base}/chat/completions",
                    headers={"Authorization": f"Bearer {self.key}", "HTTP-Referer": "http://localhost", "X-Title": "MagicBrain"},
                    json=payload)
                r.raise_for_status()
                data = r.json()
                actual_model = data.get("model", model)
                text = data.get("choices",[{}])[0].get("message",{}).get("content","")
                return f"[{actual_model}] {text}" if text else "⚠️ Пустой ответ"
        except Exception as e:
            if self.fallback: return await self._fallback(prompt, context)
            return f"⚠️ OpenRouter ошибка: {str(e)[:150]}"
    
    async def _fallback(self, prompt, context):
        from .ollama_client import OllamaClient
        return await OllamaClient().chat(model="qwen2.5:3b", prompt=prompt, context=context)
PY

echo "[4/6] Обновление orchestrator.py..."
cat << 'PY' > agents/main/orchestrator.py
import os, sys
from pathlib import Path
BASE = Path(__file__).parent.parent.parent
if str(BASE) not in sys.path: sys.path.insert(0, str(BASE))

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
            response = await self.cloud_llm.chat(prompt=optimized, context=ctx_texts)
        
        ok, issues = self.critic.validate(response)
        if not ok: return {"error": "Ответ заблокирован критиком", "issues": issues, "privacy_mode": mode}
        return {"reply": response, "privacy_mode": mode, "context_used": len(ctx_texts), "issues": issues}
PY

echo "[5/6] Проверка содержимого..."
head -3 privacy/local_llm/openrouter_client.py
echo "---"
head -3 config/openrouter.yaml

echo "[6/6] Чистый запуск API..."
set -a; source .env; set +a
export OPENROUTER_API_KEY
cd interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6

curl -sf http://127.0.0.1:8000/health > /dev/null && echo "✅ API UP" || { echo "❌ API DOWN"; tail -10 /tmp/api.log; exit 1; }

echo "🧪 Тест роутера (публичный запрос, 50с)..."
RESP=$(curl -s -X POST http://127.0.0.1:8000/process \
  -H "Content-Type: application/json" --max-time 50 \
  -d '{"user_id":1,"text":"кратко: что такое квантовый компьютер?","task_type":"default"}')
echo "$RESP" | python3 -c "
import sys,json
try:
 d=json.load(sys.stdin)
 reply = d.get('reply','')
 if 'error' in d: print(f'❌ {d[\"error\"][:100]}')
 elif '[' in reply:
  print(f'✅ РОУТЕР РАБОТАЕТ! mode:{d.get(\"privacy_mode\")}')
  print(f'🤖 Модель: {reply.split(\"]\")[0][1:]}')
  print(f'💬 Ответ: {reply.split(\"]\",1)[1].strip()[:100]}...')
 else: print(f'✅ mode:{d.get(\"privacy_mode\")} | reply:{reply[:100]}...')
except Exception as e: print(f'⚠️ Ошибка: {e}')
"
echo ""
echo "ЖДУ: вывод. Если '[qwen/...]' или '[meta-llama/...]' — OpenRouter подключён."
