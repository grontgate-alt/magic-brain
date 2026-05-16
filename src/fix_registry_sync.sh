#!/bin/bash
set -e
cd ~/magic-brain

echo "[1/3] registry.py: синхронный wait_ready + блокировка до загрузки..."
cat << 'PY' > agents/brain/registry.py
import importlib, pkgutil, inspect, os, sys, asyncio, threading, time, re
from pathlib import Path
from agents.tools.pack_manager import pack_mgr
from agents.mcp.client import mcp as mcp_client

class SkillRegistry:
    def __init__(self):
        self.skills = {}; self._base = Path(__file__).parent.parent / "tools"
        self._packs_loaded = False; self._mcp_loaded = False; self._ready = False
        self._init_lock = asyncio.Lock(); self._load_task = None
        # Не запускаем авто-загрузку здесь — будем ждать явно
    
    def is_ready(self): return self._ready
    
    async def wait_ready(self, timeout=10.0):
        """Блокирующее ожидание полной загрузки (вызывать из async контекста)"""
        if self._ready: return True
        # Если загрузка ещё не начата — запускаем её синхронно
        if not self._load_task:
            try:
                loop = asyncio.get_running_loop()
                # Запускаем загрузку и ждём её завершения
                await self.reload()
            except RuntimeError:
                # Нет event loop — создаём временный
                def run(): asyncio.new_event_loop().run_until_complete(self.reload())
                t = threading.Thread(target=run); t.start(); t.join(timeout)
        # Ждём завершения
        start = time.time()
        while not self._ready and time.time()-start < timeout:
            await asyncio.sleep(0.05)
        return self._ready
    
    def load_static(self):
        if not self._base.exists(): return
        for f in self._base.rglob("*.py"):
            if f.name.startswith("_") or "packs" in str(f): continue
            try:
                rel = f.relative_to(self._base.parent.parent)
                mod = importlib.import_module(f"agents.{str(rel.with_suffix('')).replace(os.sep, '.')}")
                for n, o in inspect.getmembers(mod):
                    if callable(o) and hasattr(o, "__skill__"):
                        m = o.__skill__(); self.skills[m.get("name",n)] = {"func":o,"desc":m.get("desc",""),"params":m.get("params",{}),"privacy":m.get("privacy","CLOUD"),"type":"static"}
            except: pass
    
    async def load_packs(self):
        if self._packs_loaded: return
        pack_mgr.sync()
        for n, m in pack_mgr.adapt().items():
            try: exec(m["code"], globals()); fn=globals().get(n)
            except: continue
            if fn: self.skills[n]={"func":fn,"desc":m["desc"],"params":{},"privacy":m["privacy"],"type":"pack"}
        self._packs_loaded = True
    
    async def load_mcp(self):
        if self._mcp_loaded: return
        await mcp_client.connect_and_load()
        for tname, meta in mcp_client.tools_meta.items():
            async def wrap(q,ctx,uid,tn=tname,**kw): return await mcp_client.execute(tn, {"query":q,**kw})
            self.skills[tname]={"func":wrap,"desc":meta["desc"],"params":meta["params"],"privacy":meta["privacy"],"type":"mcp"}
        self._mcp_loaded = True
    
    async def reload(self):
        async with self._init_lock:
            if self._ready: return
            self.skills.clear(); self._packs_loaded=False; self._mcp_loaded=False
            self.load_static()
            await self.load_packs()
            await self.load_mcp()
            self._ready = True
            print(f"✅ Registry loaded: {len(self.skills)} tools")
    
    def list(self, q=None):
        if not q: return list(self.skills.keys())
        ql = q.lower(); matched = []
        for n, m in self.skills.items():
            if n in ql or ql in m.get("desc","").lower(): matched.append(n)
        if "/" in ql or "~/" in ql or any(k in ql for k in ["файл","каталог","папка","директория","покажи","список","создай","запиши"]):
            for n in self.skills:
                if "filesystem" in n and n not in matched: matched.append(n)
        if not matched:
            matched = [n for n in self.skills if "filesystem" in n] + [n for n in self.skills if "filesystem" not in n]
        return matched
    
    def get(self, n): return self.skills.get(n)

registry = SkillRegistry()
PY
echo "✅ registry.py: синхронная загрузка"

echo "[2/3] orchestrator.py: явный wait_ready перед использованием..."
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
        # === ГАРАНТИРОВАННАЯ ЗАГРУЗКА ===
        logging.info("🔍 _agent_execute: waiting registry...")
        loaded = await registry.wait_ready(timeout=10)
        if not loaded:
            logging.warning("⚠️ Registry not ready after timeout"); return None
        logging.info(f"📦 Registry: {len(registry.skills)} tools")
        
        tools = registry.list(q)[:10]
        logging.info(f"🔧 Candidate tools: {tools[:5]}")
        if not tools: logging.warning("⚠️ No candidate tools"); return None
        
        meta = [{"name":t, "desc":registry.skills[t].get("desc",""), "params":registry.skills[t].get("params",{})} for t in tools if t in registry.skills]
        logging.info(f"📋 Tool meta count: {len(meta)}")
        
        dec = tool_router.select(q, meta)
        logging.info(f"🎯 Router decision: {dec}")
        if not dec: logging.warning("⚠️ Router returned None"); return None
        
        tn, args = dec["tool_name"], dec["args"]
        logging.info(f"⚙️ Executing: {tn} | args={args}")
        
        skill = registry.skills.get(tn)
        if skill and callable(skill.get("func")):
            res = await asyncio.wait_for(skill["func"](q, {}, uid, **args), timeout=15)
        else:
            res = await asyncio.wait_for(mcp_direct.execute(tn, args), timeout=15)
        
        logging.info(f"✅ Tool result: {len(str(res))} chars")
        return str(res) if res else f"✅ {tn} executed"

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
        logging.info(f"🚀 process() called: force_mode={repr(force_mode)}, type={type(force_mode).__name__}")
        
        force_tools = (force_agent is True) or (str(force_mode or "").lower() == "tools")
        logging.info(f"🔧 Force tools mode: {force_tools}")
        
        if force_tools:
            logging.info("🎯 Attempting agent execution...")
            res = await self._agent_execute(user_query, user_id)
            if res and not str(res).startswith("⚠️"):
                logging.info(f"✅ Agent succeeded")
                return {"reply":res, "privacy_mode":"tools", "model_used":"agent", "context_used":0, "tag":self._tag("tools","agent",0)}
            else:
                logging.warning(f"⚠️ Agent failed or returned None")
        
        logging.info("💬 Falling back to chat mode")
        txt, mu, c = await self._chat_fallback(user_query, user_id, start)
        pm = "LOCAL" if mu=="qwen2.5:3b" else "CLOUD"
        return {"reply":txt, "privacy_mode":pm, "model_used":mu, "context_used":c, "tag":self._tag("chat",mu,c)}
PY
echo "✅ orchestrator.py: явный wait_ready"

echo "[3/3] Перезапуск API + тест..."
pkill -9 -f "uvicorn.*:8000" 2>/dev/null || true; sleep 2
cd ~/magic-brain/interfaces/api
python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6

echo ""
echo "=== ТЕСТ ==="
curl -s -X POST http://127.0.0.1:8000/process \
  -H "Content-Type: application/json" \
  -d '{"user_id": 999, "text": "Покажи файлы в /home/der", "force_mode": "tools"}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('Tag:', d.get('tag')); print('Model:', d.get('model_used')); print('Reply:', d.get('reply','')[:120].replace('\n',' '))"

echo ""
echo "=== ЛОГИ ==="
tail -20 /tmp/api.log | grep -E 'Registry|Candidate|Router|Executing|force_mode|Tag:' || echo "(нет совпадений)"
