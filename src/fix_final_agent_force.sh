#!/bin/bash
set -e
cd ~/magic-brain

echo "[1/3] Orchestrator: жёсткий форс + логирование каждого шага..."
cat << 'PY' > agents/main/orchestrator.py
import os, sys, time, asyncio, logging, re
from pathlib import Path
BASE = Path(__file__).parent.parent.parent; sys.path.insert(0, str(BASE))
for ln in (BASE/".env").read_text().splitlines():
    if "=" in ln and not ln.strip().startswith("#"): k,v=ln.split("=",1); os.environ[k.strip()]=v.strip()
logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s', force=True)

from rag.router.privacy_router import PrivacyRouter
from rag.embed.local_embedder import LocalEmbedder
from rag.store.qdrant_client import RAGStore
from privacy.local_llm.ollama_client import OllamaClient
from privacy.local_llm.openrouter_client import OpenRouterClient
from privacy.vault.token_vault import TokenVault
from agents.brain.registry import registry
from agents.brain.tool_router import tool_router
from agents.mcp.client import mcp as mcp_direct

class MagicBrain:
    def __init__(self):
        logging.info("🧠 MagicBrain init...")
        self.router=PrivacyRouter(); self.embedder=LocalEmbedder(); self.store=RAGStore()
        self.local_llm=OllamaClient(); self.cloud_llm=OpenRouterClient(api_key=os.getenv("OPENROUTER_API_KEY"))
        self.vault=TokenVault()

    def _tag(self, m, mdl, c): return f"[{'🛠️' if m=='tools' else '💬'}{mdl}{' +RAG:'+str(c) if c else ''}]"

    async def _agent_execute(self, q, uid):
        logging.info(f"🔍 _agent_execute START: query={q[:40]}")
        try:
            await registry.wait_ready(timeout=5)
            logging.info(f"📦 Registry ready: {len(registry.skills)} tools")
            
            tools = registry.list(q)[:10]
            logging.info(f"🔧 Candidate tools: {tools[:5]}")
            if not tools: 
                logging.warning("⚠️ No candidate tools"); return None
            
            meta = [{"name":t, "desc":registry.skills[t].get("desc",""), "params":registry.skills[t].get("params",{})} for t in tools if t in registry.skills]
            logging.info(f"📋 Tool meta count: {len(meta)}")
            
            dec = tool_router.select(q, meta)
            logging.info(f"🎯 Router decision: {dec}")
            if not dec: 
                logging.warning("⚠️ Router returned None"); return None
            
            tn, args = dec["tool_name"], dec["args"]
            logging.info(f"⚙️ Executing: {tn} | args={args}")
            
            skill = registry.skills.get(tn)
            if skill and callable(skill.get("func")):
                res = await asyncio.wait_for(skill["func"](q, {}, uid, **args), timeout=15)
            else:
                res = await asyncio.wait_for(mcp_direct.execute(tn, args), timeout=15)
            
            logging.info(f"✅ Tool result: {len(str(res))} chars")
            return str(res) if res else f"✅ {tn} executed"
        except Exception as e:
            logging.error(f"❌ _agent_execute ERROR: {e}", exc_info=True)
            return None

    async def _chat_fallback(self, q, uid, start):
        if time.time()-start > 20: return "⏱️ Таймаут", "timeout", 0
        try:
            pm = self.router.classify(q)
            p, tok = q, {}
            if pm=="CLOUD" and self.router.needs_scrubbing(q): p, tok = self.vault.scrub(q)
            fp = f"Отвечай кратко.\nЗапрос: {p}"
            if pm=="LOCAL":
                r = await asyncio.wait_for(self.local_llm.chat(model="qwen2.5:3b", prompt=fp, context=[]), timeout=10)
                return r, "qwen2.5:3b", 0
            else:
                r = await asyncio.wait_for(self.cloud_llm.chat(prompt=fp, context=[]), timeout=10)
                if tok: r = self.vault.unscrub(r, tok)
                return r, "cloud", 0
        except asyncio.TimeoutError: return "⏱️ Таймаут", "timeout", 0
        except: return "⚠️ Ошибка", "error", 0

    async def process(self, user_query, user_id, force_mode=None, force_agent=False, **kw):
        start = time.time()
        logging.info(f"🚀 process() called: force_mode={repr(force_mode)}, force_agent={force_agent}, type(force_mode)={type(force_mode)}")
        
        # === ЖЁСТКИЙ ФОРС: проверяем явно ===
        force_tools = (force_agent is True) or (force_mode == "tools") or (str(force_mode or "").lower() == "tools")
        logging.info(f"🔧 Force tools mode: {force_tools}")
        
        if force_tools:
            logging.info("🎯 Attempting agent execution...")
            res = await self._agent_execute(user_query, user_id)
            if res and not str(res).startswith("⚠️"):
                logging.info(f"✅ Agent succeeded")
                return {"reply":res, "privacy_mode":"tools", "model_used":"agent", "context_used":0, "tag":self._tag("tools","agent",0)}
            else:
                logging.warning(f"⚠️ Agent failed or returned None, falling back")
        
        logging.info("💬 Falling back to chat mode")
        txt, mu, c = await self._chat_fallback(user_query, user_id, start)
        pm = "LOCAL" if mu=="qwen2.5:3b" else "CLOUD"
        return {"reply":txt, "privacy_mode":pm, "model_used":mu, "context_used":c, "tag":self._tag("chat",mu,c)}
PY
echo "✅ orchestrator.py: жёсткий форс + логи"

echo "[2/3] Тест напрямую (без HTTP)..."
timeout 30 python3 << 'PY'
import asyncio, time, os, sys, logging
sys.path.insert(0, '/home/der/magic-brain')
os.environ.setdefault('QDRANT_HOST', 'localhost')
logging.basicConfig(level=logging.INFO, format='%(asctime)s %(message)s')

async def main():
    from agents.main.orchestrator import MagicBrain
    brain = MagicBrain()
    # Явно передаём force_mode как строку
    res = await brain.process("Покажи файлы в /home/der", 999, force_mode="tools")
    print(f"\n🎯 RESULT: tag={res.get('tag')}, model={res.get('model_used')}")
    print(f"💬 Reply: {res.get('reply','')[:200]}")

asyncio.run(main())
PY

echo ""
echo "[3/3] Если всё ещё [💬cloud] — проверь логи выше:"
echo "  • 'Force tools mode: True' → форс сработал"
echo "  • 'Router decision: {...}' → роутер выбрал инструмент"
echo "  • 'Executing: mcp_filesystem_...' → инструмент выполняется"
echo ""
echo "Если видишь 'Router decision: None' → проблема в tool_router.select()"
echo "Если видишь 'Force tools mode: False' → проблема в передаче force_mode"
echo ""
echo "Скинь вывод секции '🎯 RESULT' и ключевые строки логов."
