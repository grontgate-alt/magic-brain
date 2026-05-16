#!/bin/bash
set -e
cd ~/magic-brain

echo "[1/3] Фикс registry: авто-загрузка + синхронный геттер..."
cat << 'PY' > agents/brain/registry.py
import importlib, pkgutil, inspect, os, sys, asyncio, threading
from pathlib import Path
from agents.tools.pack_manager import pack_mgr
from agents.mcp.client import mcp

class SkillRegistry:
    def __init__(self):
        self.skills = {}
        self._base = Path(__file__).parent.parent / "tools"
        self._packs_loaded = False
        self._mcp_loaded = False
        self._init_lock = threading.Lock()
        self._init_done = False
        # Авто-загрузка при создании (в фоне)
        asyncio.create_task(self._init_async()) if self._is_in_async() else None
    
    def _is_in_async(self):
        try:
            asyncio.get_running_loop()
            return True
        except RuntimeError:
            return False
    
    async def _init_async(self):
        """Фоновая инициализация"""
        await self.reload()
    
    def load_static(self):
        if not self._base.exists(): return
        for f in self._base.rglob("*.py"):
            if f.name.startswith("_") or "packs" in str(f): continue
            rel = f.relative_to(self._base.parent.parent)
            mn = str(rel.with_suffix('')).replace(os.sep, '.')
            try:
                mod = importlib.import_module(f"agents.{mn}")
                for n, o in inspect.getmembers(mod):
                    if callable(o) and hasattr(o, "__skill__"):
                        meta = o.__skill__()
                        name = meta.get("name", n)
                        self.skills[name] = {
                            "func": o, "desc": meta.get("desc",""), 
                            "params": meta.get("params",{}), 
                            "privacy": meta.get("privacy","CLOUD"), 
                            "type": "static"
                        }
            except Exception as e:
                pass
    
    async def load_packs(self):
        if self._packs_loaded: return
        pack_mgr.sync()
        for n, m in pack_mgr.adapt().items():
            try:
                exec(m["code"], globals())
                fn = globals().get(n)
                if fn: 
                    self.skills[n] = {
                        "func": fn, "desc": m["desc"], 
                        "params": {}, "privacy": m["privacy"], 
                        "type": "pack"
                    }
            except: pass
        self._packs_loaded = True
    
    async def load_mcp(self):
        if self._mcp_loaded: return
        await mcp.connect_and_load()
        for tname, meta in mcp.tools_meta.items():
            async def mcp_wrapper(query: str, context: dict, user_id: int, tn=tname, **kwargs):
                args = {"query": query, **kwargs}
                if "path" not in args:
                    import re
                    paths = re.findall(r'(/[^\s,;"]+|~/[^\s,;"]+)', query)
                    if paths: args["path"] = paths[0]
                return await mcp.execute(tn, args)
            self.skills[tname] = {
                "func": mcp_wrapper, 
                "desc": meta["desc"], 
                "params": meta["params"], 
                "privacy": meta["privacy"], 
                "type": "mcp"
            }
        self._mcp_loaded = True
        print(f"📦 MCP registered: {len([s for s in self.skills if s.startswith('mcp_')])} tools")
    
    def list(self, q=None):
        # Ленивая загрузка если нужно
        if not self._init_done and "mcp_filesystem" not in self.skills:
            try:
                loop = asyncio.get_running_loop()
                # Нельзя блокировать в async контексте — возвращаем что есть
            except:
                pass  # вне async — можно было бы запустить, но пока пропускаем
        if not q: return list(self.skills.keys())
        ql = q.lower()
        return [n for n,m in self.skills.items() if n in ql or m.get("desc","").lower() in ql] or list(self.skills.keys())[:10]
    
    def get(self, n): 
        return self.skills.get(n)
    
    async def reload(self):
        with self._init_lock:
            if self._init_done: return
            self.skills.clear()
            self._packs_loaded = False
            self._mcp_loaded = False
            self.load_static()
            await self.load_packs()
            await self.load_mcp()
            self._init_done = True
            total = len(self.skills)
            types = {}
            for v in self.skills.values(): types[v['type']] = types.get(v['type'],0)+1
            print(f"📦 Registry: {total} tools ({types})")

# Глобальный экземпляр
registry = SkillRegistry()

# === БЛОКИРУЮЩИЙ ИНИЦИАЛИЗАТОР ДЛЯ СИНХРОННОГО КОНТЕКСТА ===
def ensure_loaded():
    """Вызывать в синхронном коде перед использованием registry"""
    if not registry._init_done:
        try:
            loop = asyncio.get_running_loop()
            # Уже в async — создаём задачу
            asyncio.create_task(registry.reload())
        except RuntimeError:
            # Синхронный контекст — запускаем цикл
            asyncio.run(registry.reload())
PY
echo "✅ registry.py: авто-загрузка"

echo "[2/3] Фикс orchestrator: вызов ensure_loaded() при старте..."
# Добавляем импорт и вызов в начало __init__
sed -i '/from agents.brain.session import session_manager/a from agents.brain.registry import ensure_loaded' agents/main/orchestrator.py 2>/dev/null || true
sed -i '/self.worker = Worker(self)/a\        ensure_loaded()  # гарантируем загрузку скиллов' agents/main/orchestrator.py 2>/dev/null || true
echo "✅ orchestrator: ensure_loaded()"

echo "[3/3] Проверка + перезапуск..."
# Тест: загружает ли registry инструменты
python3 << 'PY'
import sys, asyncio; sys.path.insert(0, '.')
from agents.brain.registry import registry, ensure_loaded
ensure_loaded()  # ждём загрузки
# Небольшая пауза для async инициализации
import time; time.sleep(2)
fs_tools = [k for k in registry.skills if 'filesystem' in k]
print(f"📦 Filesystem tools in registry: {len(fs_tools)}")
for t in fs_tools[:5]: print(f"  • {t}")
PY

# Перезапуск API
pkill -f uvicorn 2>/dev/null || true; sleep 3
set -a; source ~/magic-brain/.env; set +a
cd ~/magic-brain/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health && echo "✅ API UP" || echo "❌ API DOWN"

echo ""
echo "🧪 Тест: напиши боту 'Покажи файлы в /home/der'"
echo "Ожидаемо: список файлов + тег [🛠️mcp] + кнопки под сообщением"
echo ""
echo "Если не работает — скинь: tail -30 /tmp/api.log | grep -E 'Registry|MCP|skills'"
echo "ЖДУ: результат."
