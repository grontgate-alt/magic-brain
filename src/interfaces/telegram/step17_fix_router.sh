#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain
cd $BASE

echo "[1/5] Конфиг роутера OpenRouter (качественные бесплатные модели)..."
mkdir -p config
cat << 'YAML' > config/openrouter.yaml
# Настройки OpenRouter Free Router
free_router:
  model: "openrouter/free"       # Встроенный роутер бесплатных моделей
  route: "quality"               # Стратегия: quality / cost / balanced
  # Белый список (опционально): ограничивает пул только этими моделями
  # allowed_models:
  #   - "qwen/qwen-2.5-7b-instruct:free"
  #   - "meta-llama/llama-3.3-70b-instruct:free"
  #   - "deepseek/deepseek-chat:free"
  timeout: 45
  fallback_local: true           # При ошибке роутера → локальная qwen2.5:3b
YAML

echo "[2/5] Обновление openrouter_client.py..."
cat << 'PY' > privacy/local_llm/openrouter_client.py
import httpx, os, sys, yaml
from pathlib import Path
BASE = Path(__file__).parent.parent.parent
if str(BASE) not in sys.path: sys.path.insert(0, str(BASE))
from rag.router.privacy_router import PrivacyRouter

class OpenRouterClient:
    def __init__(self, api_key: str = None, router: PrivacyRouter = None, config_path: str = "config/openrouter.yaml"):
        self.key = api_key or os.getenv("OPENROUTER_API_KEY", "").strip()
        self.router = router or PrivacyRouter()
        self.base = "https://openrouter.ai/api/v1"
        
        cfg = Path(BASE / config_path if not Path(config_path).is_absolute() else config_path)
        self.cfg = yaml.safe_load(cfg.read_text())["free_router"] if cfg.exists() else {}
    
    async def chat(self, prompt: str, context: list[str] = None, **kwargs) -> str:
        if not self.key:
            return await self._fallback(prompt, context)
        
        safe_prompt = self.router.scrub(prompt)
        safe_ctx = [self.router.scrub(c) for c in (context or [])]
        ctx = "\n\nКонтекст:\n" + "\n---\n".join(safe_ctx) if safe_ctx else ""
        
        payload = {
            "model": self.cfg.get("model", "openrouter/free"),
            "route": self.cfg.get("route", "balanced"),
            "messages": [{"role": "user", "content": ctx + "\n\n" + safe_prompt}]
        }
        if "allowed_models" in self.cfg:
            payload["allowed_models"] = self.cfg["allowed_models"]
            
        try:
            async with httpx.AsyncClient(timeout=self.cfg.get("timeout", 45)) as c:
                r = await c.post(f"{self.base}/chat/completions",
                    headers={"Authorization": f"Bearer {self.key}", "HTTP-Referer": "http://localhost", "X-Title": "MagicBrain"},
                    json=payload)
                r.raise_for_status()
                data = r.json()
                actual_model = data.get("model", "unknown")
                text = data.get("choices",[{}])[0].get("message",{}).get("content","")
                return f"[{actual_model}] {text}" if text else "⚠️ Пустой ответ"
        except Exception as e:
            if self.cfg.get("fallback_local", True):
                return await self._fallback(prompt, context)
            return f"⚠️ OpenRouter ошибка: {str(e)[:150]}"
    
    async def _fallback(self, prompt, context):
        from .ollama_client import OllamaClient
        local = OllamaClient()
        return await local.chat(model="qwen2.5:3b", prompt=prompt, context=context)
PY

echo "[3/5] Обновление orchestrator.py (убран хардкод моделей)..."
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
        if not ok:
            return {"error": "Ответ заблокирован критиком", "issues": issues, "privacy_mode": mode}
        return {"reply": response, "privacy_mode": mode, "context_used": len(ctx_texts), "issues": issues}
PY

echo "[4/5] Перезапуск API..."
pkill -9 -f "uvicorn\|python3.*bot" 2>/dev/null || true
sleep 3
set -a; source .env; set +a
cd interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health > /dev/null && echo "✅ API UP" || { echo "❌ API DOWN"; tail -10 /tmp/api.log; exit 1; }

echo "[5/5] Тест через Free Router..."
RESP=$(curl -s -X POST http://127.0.0.1:8000/process \
  -H "Content-Type: application/json" --max-time 50 \
  -d '{"user_id":1,"text":"кратко: что такое квантовый компьютер?","task_type":"default"}')
echo "$RESP" | python3 -c "
import sys,json
try:
 d=json.load(sys.stdin)
 if 'error' in d: print(f'❌ {d[\"error\"][:120]}')
 else: print(f'✅ mode:{d.get(\"privacy_mode\")} | model:{d.get(\"reply\",\"\")[:20]}... | reply:{d.get(\"reply\",\"\")[20:90]}...')
except: print('⚠️ Таймаут или ошибка')
"
echo ""
echo "📝 Требования к моделям задаются в config/openrouter.yaml (allowed_models, route)."
echo "ЖДУ: вывод. Если в ответе есть [model_name] — роутер работает."
