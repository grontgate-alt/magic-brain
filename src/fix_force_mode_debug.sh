#!/bin/bash
set -e
cd ~/magic-brain

echo "[1/3] API: гарантированная передача force_mode + логи..."
cat << 'PY' > interfaces/api/main.py
import os, sys, json, logging
from pathlib import Path
from fastapi import FastAPI
from pydantic import BaseModel
from typing import Optional

sys.path.insert(0, str(Path(__file__).parent.parent.parent))
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

app = FastAPI()

class Req(BaseModel):
    user_id: int
    text: str
    force_mode: Optional[str] = None
    force_agent: Optional[bool] = False

@app.get("/health")
async def health(): return {"status":"ok"}

@app.post("/process")
async def process(r: Req):
    logging.info(f"📥 API request: user={r.user_id}, text={r.text[:50]}, force_mode={r.force_mode}, force_agent={r.force_agent}")
    try:
        from agents.main.orchestrator import MagicBrain
        brain = MagicBrain()
        res = await brain.process(
            user_query=r.text, 
            user_id=r.user_id, 
            force_mode=r.force_mode,
            force_agent=r.force_agent
        )
        logging.info(f"📤 API response: tag={res.get('tag')}, model={res.get('model_used')}")
        return res
    except Exception as e:
        logging.error(f"❌ API CRASH: {e}", exc_info=True)
        return {"reply": f"⚠️ Ошибка: {str(e)[:120]}", "privacy_mode":"error", "model_used":"crash", "context_used":0, "tag":"[❌]"}
PY
echo "✅ main.py: логи + передача force_mode"

echo "[2/3] Orchestrator: отладка агентского выбора + жёсткий форс..."
cat << 'PY' > agents/main/orchestrator.py
import os, sys, uuid, re, asyncio, logging, time, json
from pathlib import Path
BASE_DIR = Path(__file__).parent.parent.parent
sys.path.insert(0, str(BASE_DIR))
for ln in (BASE_DIR/".env").read_text().splitlines():
    if "=" in ln and not ln.strip().startswith("#"): k,v=ln.split("=",1); os.environ[k.strip()]=v.strip()

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s', force=True)
from rag.router.privacy_router import PrivacyRouter
from rag.embed.local_embedder import LocalEmbedder
from rag.store.qdrant_client import RAGStore
from privacy.local_llm.ollama_client import OllamaClient
from privacy.local_llm.openrouter_client import OpenRouterClient
from privacy.vault.token_vault import TokenVault
from agents.brain.registry import registry
from agents.brain.tool_router import ToolRouter
from agents.mcp.client import mcp as mcp_direct

class MagicBrain:
    def __init__(self):
        logging.info("🧠 Init MagicBrain...")
        self.router = PrivacyRouter(); self.embedder = LocalEmbedder(); self.store = RAGStore()
        self.local_llm = OllamaClient()
        self.cloud_llm = OpenRouterClient(api_key=os.getenv("OPENROUTER_API_KEY"))
        self.vault = TokenVault()
        self.tool_router = ToolRouter(self)

    def _tag(self, m, mdl, c): return f"[{'🛠️' if m=='tools' else '💬'}{mdl}{' +RAG:'+str(c) if c else ''}]"

    async def _agent_execute(self, query: str, user_id: int) -> str:
        """Агент: выбирает и выполняет инструмент. Возвращает результат ИЛИ None."""
        try:
            logging.info(f"🔍 Agent: waiting registry...")
            await registry.wait_ready(timeout=8)
            logging.info(f"📦 Registry: {len(registry.skills)} tools loaded")
            
            tools = registry.list(query)[:8]
            logging.info(f"🔧 Relevant tools: {tools[:3]}")
            if not tools: 
                logging.warning("⚠️ Agent: no relevant tools found")
                return None
            
            tool_meta = [{"name":t, "desc":registry.skills[t].get("desc",""), "params":registry.skills[t].get("params",{})} for t in tools if t in registry.skills]
            if not tool_meta: 
                logging.warning("⚠️ Agent: no valid tool metadata")
                return None
            
            logging.info(f"🤖 Agent: calling tool_router...")
            decision = await self.tool_router.select_and_parse(query, tool_meta)
            logging.info(f"🎯 Router decision: {decision}")
            
            if not decision or not decision.get("tool_name"): 
                logging.warning("⚠️ Agent: router returned null")
                return None
            
            tn, args = decision["tool_name"], decision["args"]
            logging.info(f"⚙️ Executing: {tn} with args: {args}")
            
            skill = registry.skills.get(tn)
            if skill and callable(skill.get("func")):
                result = await asyncio.wait_for(skill["func"](query, {}, user_id, **args), timeout=30)
            else:
                result = await asyncio.wait_for(mcp_direct.execute(tn, args), timeout=30)
                
            logging.info(f"✅ Tool executed: {len(str(result))} chars")
            return str(result) if result else f"✅ {tn} executed"
            
        except Exception as e:
            logging.error(f"❌ Agent execution failed: {e}", exc_info=True)
            return None

    async def _chat_fallback(self, q, uid, start):
        if time.time()-start > 30: return "⏱️ Таймаут", "timeout", 0
        try:
            pm = self.router.classify(q)
            prompt, tok = q, {}
            if pm=="CLOUD" and self.router.needs_scrubbing(q): prompt, tok = self.vault.scrub(q)
            vec = self.embedder.embed([prompt])[0]
            ctx = [(r.get("payload") or r.get("meta") or {}).get("text","") for r in self.store.search(vec, limit=3)]
            fp = f"Отвечай кратко.\nЗапрос: {prompt}"
            if pm=="LOCAL":
                r = await asyncio.wait_for(self.local_llm.chat(model="qwen2.5:3b", prompt=fp, context=[]), timeout=12)
                return r, "qwen2.5:3b", len(ctx)
            else:
                r = await asyncio.wait_for(self.cloud_llm.chat(prompt=fp, context=[]), timeout=12)
                if tok: r = self.vault.unscrub(r, tok)
                return r, "cloud", len(ctx)
        except asyncio.TimeoutError: return "⏱️ Таймаут", "timeout", 0
        except Exception as e: return f"⚠️ {str(e)[:80]}", "error", 0

    async def process(self, user_query: str, user_id: int, force_mode: str = None, force_agent: bool = False, **kw):
        start = time.time()
        logging.info(f"🚀 Process: force_mode={force_mode}, force_agent={force_agent}")
        
        # === ЖЁСТКИЙ ФОРС АГЕНТА ===
        if force_agent or force_mode == "tools":
            logging.info("🔧 Force agent mode requested")
            agent_res = await self._agent_execute(user_query, user_id)
            if agent_res:
                logging.info(f"✅ Agent succeeded")
                return {"reply": agent_res, "privacy_mode": "tools", "model_used": "agent", "context_used": 0, "tag": self._tag("tools", "agent", 0)}
            else:
                logging.warning("⚠️ Agent failed, falling back to chat")
        
        # === Обычный поток ===
        txt, mu, c = await self._chat_fallback(user_query, user_id, start)
        pm = "LOCAL" if mu=="qwen2.5:3b" else "CLOUD"
        return {"reply": txt, "privacy_mode": pm, "model_used": mu, "context_used": c, "tag": self._tag("chat", mu, c)}
PY
echo "✅ orchestrator.py: отладка + жёсткий форс"

echo "[3/3] Перезапуск + тест..."
pkill -f "uvicorn.*:8000" 2>/dev/null || true; sleep 2
set -a; source ~/magic-brain/.env; set +a
cd ~/magic-brain/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 5

echo ""
echo "=== ТЕСТ: force_mode=tools ==="
curl -s -X POST http://127.0.0.1:8000/process \
  -H "Content-Type: application/json" \
  -d '{"user_id": 999, "text": "Покажи файлы в /home/der", "force_mode": "tools"}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('tag:', d.get('tag')); print('model:', d.get('model_used')); print('reply:', d.get('reply','')[:200])"

echo ""
echo "=== ЛОГИ АГЕНТА ==="
tail -40 /tmp/api.log | grep -E 'Agent|Router|Executing|Registry|force_mode'
