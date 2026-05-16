#!/bin/bash
set -e
cd ~/magic-brain

echo "[1/2] Фикс registry.list(): правильный поиск + приоритет путей..."
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
        self._schedule_init()
    
    def _schedule_init(self):
        try: loop = asyncio.get_running_loop(); self._load_task = loop.create_task(self.reload())
        except RuntimeError:
            def run(): asyncio.new_event_loop().run_until_complete(self.reload())
            threading.Thread(target=run, daemon=True).start()
    
    def is_ready(self): return self._ready
    async def wait_ready(self, timeout=10.0):
        if self._ready: return True
        start = time.time()
        while not self._ready and time.time()-start < timeout: await asyncio.sleep(0.1)
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
            self.load_static(); await self.load_packs(); await self.load_mcp()
            self._ready=True
    
    def list(self, q=None):
        if not q: return list(self.skills.keys())
        ql = q.lower()
        matched = []
        # 1. Прямое совпадение имени или описания
        for n, m in self.skills.items():
            if n in ql or ql in m.get("desc","").lower(): matched.append(n)
        # 2. Если есть путь или запрос про файлы/каталоги - явно добавляем filesystem инструменты
        if "/" in ql or "~/" in ql or any(k in ql for k in ["файл","каталог","папка","директория","покажи","список","создай","запиши"]):
            for n in self.skills:
                if "filesystem" in n and n not in matched: matched.append(n)
        # 3. Если пусто - возвращаем все, но filesystem первые
        if not matched:
            matched = [n for n in self.skills if "filesystem" in n] + [n for n in self.skills if "filesystem" not in n]
        return matched
    
    def get(self, n): return self.skills.get(n)

registry = SkillRegistry()
PY
echo "✅ registry.py: исправлен поиск кандидатов"

echo "[2/2] Перезапуск API + тест..."
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
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('tag:', d.get('tag')); print('model:', d.get('model_used')); print('reply:', d.get('reply','')[:200].replace('\n',' '))"

echo ""
echo "=== ЛОГИ АГЕНТА ==="
tail -20 /tmp/api.log | grep -E 'Agent|Router|Executing|Registry|force|🎯|⚙️|✅|❌' || echo "(пусто или нет совпадений)"
