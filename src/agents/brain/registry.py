import importlib, pkgutil, inspect, os, sys, asyncio, threading, time, re
from pathlib import Path
from agents.tools.pack_manager import pack_mgr
from agents.mcp.connector import mcp
from agents.mcp.client import mcp as mcp_client

class SkillRegistry:
    def __init__(self):
        self.skills = {}; self._base = Path(__file__).parent.parent / "tools"
        self._packs_loaded = False; self._mcp_loaded = False; self._ready = False
        self._mcp_task = None
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
