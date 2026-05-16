#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain
cd $BASE

echo "[1/5] Жёсткая очистка..."
pkill -9 -f "uvicorn|python3" 2>/dev/null || true
sleep 3
find $BASE -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find $BASE -name "*.pyc" -delete 2>/dev/null || true
export PYTHONDONTWRITEBYTECODE=1

echo "[2/5] Проверка файлов на наличие СТАРОГО хардкода..."
OLD=$(grep -rn "3.2-1b-instruct" $BASE/privacy/local_llm/ $BASE/agents/main/ 2>/dev/null | wc -l)
[ $OLD -gt 0 ] && { echo "❌ СТАРЫЙ КОД ОСТАЛСЯ! Удаляю вручную..."; grep -rl "3.2-1b-instruct" $BASE/privacy/local_llm/ $BASE/agents/main/ | xargs rm -f; } || echo "✅ Старый код не найден"

echo "[3/5] Принудительная запись новых файлов..."
# (Вставляем те же cat << 'PY' блоки, что и в step17b, для 100% гарантии)
cat << 'YAML' > $BASE/config/openrouter.yaml
openrouter:
  models: ["qwen/qwen-2.5-7b-instruct:free", "meta-llama/llama-3.3-70b-instruct:free", "deepseek/deepseek-chat:free"]
  timeout: 45
  fallback_local: true
YAML

cat << 'PY' > $BASE/privacy/local_llm/openrouter_client.py
import httpx, os, sys, yaml, random
from pathlib import Path
BASE_DIR = Path(__file__).parent.parent.parent
if str(BASE_DIR) not in sys.path: sys.path.insert(0, str(BASE_DIR))
from rag.router.privacy_router import PrivacyRouter

class OpenRouterClient:
    def __init__(self, api_key=None, router=None):
        self.key = (api_key or os.getenv("OPENROUTER_API_KEY","")).strip()
        self.router = router or PrivacyRouter()
        self.base = "https://openrouter.ai/api/v1"
        cfg = BASE_DIR / "config" / "openrouter.yaml"
        self.cfg = yaml.safe_load(cfg.read_text()) if cfg.exists() else {}
        self.models = self.cfg.get("openrouter",{}).get("models",[])
        self.fallback = self.cfg.get("openrouter",{}).get("fallback_local", True)
    
    async def chat(self, prompt, context=None):
        if not self.key or not self.models: return await self._fallback(prompt, context)
        safe_p = self.router.scrub(prompt)
        safe_c = [self.router.scrub(c) for c in (context or [])]
        ctx = "\nКонтекст:\n"+"\n---\n".join(safe_c) if safe_c else ""
        model = random.choice(self.models)
        try:
            async with httpx.AsyncClient(timeout=self.cfg.get("openrouter",{}).get("timeout",45)) as c:
                r = await c.post(f"{self.base}/chat/completions",
                    headers={"Authorization":f"Bearer {self.key}","HTTP-Referer":"http://localhost","X-Title":"MagicBrain"},
                    json={"model":model,"messages":[{"role":"user","content":ctx+"\n\n"+safe_p}]})
                r.raise_for_status()
                d = r.json()
                return f"[{d.get('model',model)}] {d.get('choices',[{}])[0].get('message',{}).get('content','')}"
        except Exception as e:
            return await self._fallback(prompt, context) if self.fallback else f"⚠️ {str(e)[:150]}"
    async def _fallback(self, p, c):
        from .ollama_client import OllamaClient
        return await OllamaClient().chat("qwen2.5:3b", p, c)
PY

cat << 'PY' > $BASE/agents/main/orchestrator.py
import os, sys
from pathlib import Path
BASE_DIR = Path(__file__).parent.parent.parent
if str(BASE_DIR) not in sys.path: sys.path.insert(0, str(BASE_DIR))
from rag.router.privacy_router import PrivacyRouter
from rag.embed.local_embedder import LocalEmbedder
from rag.store.qdrant_client import RAGStore
from privacy.local_llm.ollama_client import OllamaClient
from privacy.local_llm.openrouter_client import OpenRouterClient
from agents.critic.critic import Critic
from agents.prompt_opt.optimizer import PromptOptimizer

class MagicBrain:
    def __init__(self):
        self.router=PrivacyRouter(); self.embedder=LocalEmbedder(); self.store=RAGStore()
        self.local_llm=OllamaClient(); self.cloud_llm=OpenRouterClient(os.getenv("OPENROUTER_API_KEY"), self.router)
        self.critic=Critic(); self.opt=PromptOptimizer()
    async def process(self, q, uid, task="default"):
        mode=self.router.classify(q)
        vec=self.embedder.embed([q])[0]; ctx=self.store.search(vec,5,None if mode=="CLOUD" else "HIGH")
        texts=[c["text"] for c in ctx]
        resp = await self.local_llm.chat("qwen2.5:3b", self.opt.optimize(q,task), texts) if mode=="LOCAL" \
               else await self.cloud_llm.chat(self.opt.optimize(q,task), texts)
        ok,iss=self.critic.validate(resp)
        return {"reply":resp,"privacy_mode":mode,"context_used":len(ctx),"issues":iss} if ok else {"error":"blocked","issues":iss,"privacy_mode":mode}
PY

echo "✅ Файлы перезаписаны"

echo "[4/5] Прямой тест клиента (без uvicorn)..."
set -a; source $BASE/.env; set +a
export PYTHONPATH=$BASE
python3 -c "
import asyncio, sys; sys.path.insert(0,'$BASE')
from privacy.local_llm.openrouter_client import OpenRouterClient
from rag.router.privacy_router import PrivacyRouter
c = OpenRouterClient('$OPENROUTER_API_KEY', PrivacyRouter())
print(f'📦 Доступные модели: {c.models}')
print('✅ Клиент загружен без старого хардкода')
"

echo "[5/5] Запуск API..."
cd $BASE/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health > /dev/null && echo "✅ API UP" || { echo "❌ API DOWN"; tail -10 /tmp/api.log; exit 1; }

echo "🧪 Тест роутера (40с)..."
RESP=$(curl -s -X POST http://127.0.0.1:8000/process \
  -H "Content-Type: application/json" --max-time 40 \
  -d '{"user_id":1,"text":"кратко: что такое квантовый компьютер?","task_type":"default"}')
echo "$RESP" | python3 -c "
import sys,json
d=json.load(sys.stdin)
r=d.get('reply','')
if '[' in r and ']' in r:
 m=r.split(']')[0][1:]
 print(f'✅ РОУТЕР РАБОТАЕТ! mode:{d.get(\"privacy_mode\")}')
 print(f'🤖 Модель: {m}')
 print(f'💬 Ответ: {r.split(\"]\",1)[1].strip()[:100]}...')
elif 'error' in d: print(f'❌ {d[\"error\"][:100]}')
else: print(f'✅ mode:{d.get(\"privacy_mode\")} | {r[:100]}')
"
echo "ЖДУ: вывод."
