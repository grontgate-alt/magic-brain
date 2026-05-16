#!/bin/bash
set -e
cd ~/magic-brain

echo "[1/4] Registry: асинхронная загрузка + ready-flag + fallback..."
cat << 'PY' > agents/brain/registry.py
import importlib, pkgutil, inspect, os, sys, asyncio, threading, time
from pathlib import Path
from agents.tools.pack_manager import pack_mgr
from agents.mcp.client import mcp as mcp_client

class SkillRegistry:
    def __init__(self):
        self.skills = {}
        self._base = Path(__file__).parent.parent / "tools"
        self._packs_loaded = False
        self._mcp_loaded = False
        self._ready = False
        self._init_lock = asyncio.Lock()
        self._load_task = None
        # Запускаем фоновую загрузку
        self._schedule_init()
    
    def _schedule_init(self):
        """Планирует загрузку в текущем или новом event loop"""
        try:
            loop = asyncio.get_running_loop()
            self._load_task = loop.create_task(self.reload())
        except RuntimeError:
            # Нет активного loop — создаём отдельный поток
            def run_in_thread():
                loop = asyncio.new_event_loop()
                asyncio.set_event_loop(loop)
                loop.run_until_complete(self.reload())
            threading.Thread(target=run_in_thread, daemon=True).start()
    
    def is_ready(self) -> bool:
        """Готов ли реестр к использованию?"""
        return self._ready or (self._load_task and not self._load_task.done())
    
    async def wait_ready(self, timeout: float = 10.0) -> bool:
        """Ждёт готовности реестра (для синхронных вызовов)"""
        if self._ready:
            return True
        start = time.time()
        while not self._ready and time.time() - start < timeout:
            await asyncio.sleep(0.1)
        return self._ready
    
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
        await mcp_client.connect_and_load()
        for tname, meta in mcp_client.tools_meta.items():
            async def mcp_wrapper(query: str, context: dict, user_id: int, tn=tname, **kwargs):
                args = {"query": query, **kwargs}
                if "path" not in args:
                    import re
                    paths = re.findall(r'(/[^\s,;"]+|~/[^\s,;"]+)', query)
                    if paths: args["path"] = paths[0]
                return await mcp_client.execute(tn, args)
            self.skills[tname] = {
                "func": mcp_wrapper, 
                "desc": meta["desc"], 
                "params": meta["params"], 
                "privacy": meta["privacy"], 
                "type": "mcp"
            }
        self._mcp_loaded = True
    
    async def reload(self):
        async with self._init_lock:
            if self._ready: return
            print("🔄 Registry: loading...")
            self.skills.clear()
            self._packs_loaded = False
            self._mcp_loaded = False
            self.load_static()
            await self.load_packs()
            await self.load_mcp()
            self._ready = True
            total = len(self.skills)
            types = {}
            for v in self.skills.values(): types[v['type']] = types.get(v['type'],0)+1
            print(f"✅ Registry ready: {total} tools ({types})")
    
    def list(self, q=None):
        if not q: return list(self.skills.keys())
        ql = q.lower()
        return [n for n,m in self.skills.items() if n in ql or m.get("desc","").lower() in ql] or list(self.skills.keys())[:10]
    
    def get(self, n): 
        return self.skills.get(n)
    
    def get_by_type(self, t: str):
        return {n: m for n, m in self.skills.items() if m.get("type") == t}

# Глобальный экземпляр
registry = SkillRegistry()

# Утилита для синхронного ожидания (если нужно)
def wait_for_ready(timeout: float = 10.0) -> bool:
    try:
        loop = asyncio.get_running_loop()
        # В async контексте — возвращаем статус, ждёт вызывающий
        return registry.is_ready()
    except RuntimeError:
        # Синхронный контекст — можно запустить цикл
        return asyncio.run(registry.wait_ready(timeout))
PY
echo "✅ registry.py: async init + ready flag"

echo "[2/4] Orchestrator: ждём registry + fallback на прямой MCP..."
cat << 'PY' > agents/main/orchestrator.py
import os, sys, uuid, re, asyncio, json, logging, time
from pathlib import Path
BASE_DIR = Path(__file__).parent.parent.parent
env_file = BASE_DIR / ".env"
if env_file.exists():
    for ln in env_file.read_text().splitlines():
        if "=" in ln and not ln.strip().startswith("#"):
            k,v = ln.split("=",1); os.environ[k.strip()] = v.strip()
if str(BASE_DIR) not in sys.path: sys.path.insert(0, str(BASE_DIR))

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s', force=True)
from rag.router.privacy_router import PrivacyRouter
from rag.embed.local_embedder import LocalEmbedder
from rag.store.qdrant_client import RAGStore
from privacy.local_llm.ollama_client import OllamaClient
from privacy.local_llm.openrouter_client import OpenRouterClient
from privacy.vault.token_vault import TokenVault
from agents.brain.planner import Planner
from agents.brain.worker import Worker
from agents.brain.critic_loop import CriticLoop
from agents.brain.intent_router import intent_router
from agents.brain.session import session_manager
from agents.brain.registry import registry, wait_for_ready
from agents.mcp.client import mcp as mcp_direct  # fallback

class MagicBrain:
    def __init__(self):
        logging.info("🧠 Initializing MagicBrain...")
        self.router = PrivacyRouter()
        self.embedder = LocalEmbedder()
        self.store = RAGStore()
        self.local_llm = OllamaClient()
        self.cloud_llm = OpenRouterClient(api_key=os.getenv("OPENROUTER_API_KEY"), router=self.router)
        self.vault = TokenVault()
        self.planner = Planner()
        self.critic = CriticLoop()
        self.worker = Worker(self)
        logging.info("✅ MagicBrain initialized")

    def _auto_save(self, text, user_id, role):
        try:
            vec = self.embedder.embed([text])[0]
            self.store.upsert([vec], [{"text": text, "user_id": user_id, "role": role, "privacy": "HIGH"}], [str(uuid.uuid4())])
        except Exception as e: logging.warning(f"RAG save: {e}")

    def _make_tag(self, mode: str, model: str, rag_count: int) -> str:
        icons = {"chat": "💬", "tools": "🛠️", "rag_direct": "🗄️", "web_search": "🌐", "LOCAL": "🔐", "CLOUD": "☁️"}
        icon = icons.get(mode, icons.get("chat"))
        rag_part = f" +RAG:{rag_count}" if rag_count > 0 else ""
        return f"[{icon}{model}{rag_part}]"

    async def _exec_via_registry(self, tool_name: str, args: dict) -> str:
        """Выполняет инструмент через registry (предпочтительный путь)"""
        skill = registry.get(tool_name)
        if not skill or not callable(skill.get("func")):
            return None  # не найдено → попробуем fallback
        try:
            # Обёртка для MCP-инструментов принимает (query, context, user_id, **kwargs)
            result = await skill["func"]("", {}, 0, **args)
            return str(result) if result else "✅ Выполнено"
        except Exception as e:
            logging.warning(f"Registry exec error: {e}")
            return None

    async def _exec_via_direct_mcp(self, tool_name: str, args: dict) -> str:
        """Fallback: прямой вызов MCP если registry не готов"""
        try:
            result = await mcp_direct.execute(tool_name, args)
            return str(result) if result else "✅ Выполнено"
        except Exception as e:
            logging.error(f"Direct MCP error: {e}")
            return None

    async def _try_direct_mcp(self, query: str, user_id: int) -> str:
        """Пытается выполнить MCP-инструмент: сначала registry, потом fallback"""
        q = query.lower()
        path_match = re.search(r'(/[a-zA-Z0-9./_~-]+|~/[a-zA-Z0-9./_~-]+)', q)
        
        if path_match:
            path = path_match.group(0)
            logging.info(f"🔍 MCP path: {path}")
            
            if any(kw in q for kw in ["прочитай", "открой", "покажи содержимое", "читать", "текст", "содержимое"]):
                tool = "mcp_filesystem_read_text_file"
            elif any(kw in q for kw in ["список", "каталог", "ls", "dir", "файлы в", "покажи", "папки"]):
                tool = "mcp_filesystem_list_directory"
            elif any(kw in q for kw in ["создай", "запиши", "сохрани", "напиши в"]):
                tool = "mcp_filesystem_write_file"
            else:
                tool = "mcp_filesystem_list_directory"
            
            logging.info(f"🔧 Tool: {tool}")
            
            # 1. Ждём готовности registry (до 5 сек)
            await registry.wait_ready(timeout=5.0)
            
            # 2. Пробуем через registry
            if registry.is_ready() and registry.get(tool):
                logging.info(f"✅ Using registry for {tool}")
                result = await self._exec_via_registry(tool, {"path": path})
                if result: return result
            
            # 3. Fallback на прямой MCP
            logging.info(f"⚠️ Registry not ready, using direct MCP for {tool}")
            return await self._exec_via_direct_mcp(tool, {"path": path})
        
        # GitHub поиск
        if any(kw in q for kw in ["github", "репозиторий", "репо"]):
            tool = "mcp_github_search_repositories"
            search = re.search(r'(?:про|о|найти|поиск).*?([a-zA-Z0-9а-яА-ЯёЁ_\-\s]{3,})', q, re.I)
            query_arg = search.group(1).strip() if search else "ai"
            await registry.wait_ready(timeout=5.0)
            if registry.is_ready() and registry.get(tool):
                result = await self._exec_via_registry(tool, {"query": query_arg})
                if result: return result
            return await self._exec_via_direct_mcp(tool, {"query": query_arg})
        
        return None

    async def process(self, user_query: str, user_id: int, task_type: str = "default", 
                      force_agent: bool = False, force_mode: str = None, intent_override: str = None) -> dict:
        start = time.time()
        logging.info(f"🚀 Process: user={user_id}, query={user_query[:60]}")
        
        self._auto_save(f"USER: {user_query}", user_id, "query")
        
        # === ПРЯМОЙ MCP ДЛЯ ПУТЕЙ ===
        if force_agent or force_mode == "tools" or "/home" in user_query or "~/" in user_query:
            logging.info("🔧 Attempting MCP...")
            mcp_result = await self._try_direct_mcp(user_query, user_id)
            if mcp_result and not mcp_result.startswith("⚠️"):
                logging.info(f"✅ MCP done in {time.time()-start:.2f}s")
                self._auto_save(f"ASSISTANT: {mcp_result}", user_id, "response")
                return {"reply": mcp_result, "privacy_mode": "tools", "model_used": "mcp", "context_used": 0, "tag": self._make_tag("tools", "mcp", 0)}
        
        # === Fallback: быстрый ответ при таймауте ===
        if time.time() - start > 30:
            return {"reply": "⏱️ Превышено время. Повторите.", "privacy_mode": "LOCAL", "model_used": "timeout", "context_used": 0, "tag": "[⏱️]"}
        
        # === Обычный поток (упрощённый) ===
        try:
            privacy_mode = self.router.classify(user_query)
            prompt = user_query
            tokens = {}
            if privacy_mode == "CLOUD" and self.router.needs_scrubbing(user_query):
                prompt, tokens = self.vault.scrub(user_query)
            
            vec = self.embedder.embed([prompt])[0]
            ctx = [(r.get("payload") or r.get("meta") or {}).get("text","") for r in self.store.search(vec, limit=2)]
            
            system = "Отвечай кратко."
            fp = f"{system}\n\nЗапрос: {prompt}"
            
            if privacy_mode == "LOCAL":
                resp = await asyncio.wait_for(self.local_llm.chat(model="qwen2.5:3b", prompt=fp, context=[]), timeout=20)
                mu = "qwen2.5:3b"
            else:
                resp = await asyncio.wait_for(self.cloud_llm.chat(prompt=fp, context=[]), timeout=20)
                mu = "cloud"
            
            if tokens and privacy_mode == "CLOUD":
                resp = self.vault.unscrub(resp, tokens)
            
            self._auto_save(f"ASSISTANT: {resp}", user_id, "response")
            return {"reply": resp, "privacy_mode": privacy_mode, "model_used": mu, "context_used": len(ctx), "tag": self._make_tag("chat", mu, len(ctx))}
        except asyncio.TimeoutError:
            return {"reply": "⏱️ Таймаут. Попробуйте позже.", "privacy_mode": "LOCAL", "model_used": "timeout", "context_used": 0, "tag": "[⏱️]"}
        except Exception as e:
            logging.error(f"❌ Error: {e}")
            return {"reply": f"⚠️ {str(e)[:80]}", "privacy_mode": "LOCAL", "model_used": "error", "context_used": 0, "tag": "[❌]"}
PY
echo "✅ orchestrator: registry + fallback"

echo "[3/4] Bot: таймауты + кнопки..."
# (код бота аналогичен предыдущему, с кнопками и таймаутом 35с)
# Для краткости не дублирую — используй предыдущий bot.py с кнопками

echo "[4/4] Перезапуск + проверка..."
pkill -f uvicorn 2>/dev/null || true; sleep 3
set -a; source ~/magic-brain/.env; set +a
cd ~/magic-brain/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 8  # даём время на асинхронную загрузку

# Проверка: загружен ли registry
python3 << 'PY'
import sys, asyncio, time; sys.path.insert(0, '.')
from agents.brain.registry import registry
async def check():
    await registry.wait_ready(timeout=10)
    fs = [k for k in registry.skills if 'filesystem' in k]
    print(f"📦 Registry: {len(registry.skills)} tools, filesystem: {len(fs)}")
    if fs: print(f"   Пример: {fs[0]}")
asyncio.run(check())
PY

curl -sf http://127.0.0.1:8000/health && echo "✅ API UP" || echo "❌ API DOWN"

echo ""
echo "🎉 Готово! Теперь:"
echo "  • Registry загружается асинхронно в фоне"
echo "  • process() ждёт до 5 сек готовности реестра"
echo "  • Если registry не готов — fallback на прямой MCP"
echo "  • Registry остаётся единым источником истины для инструментов"
echo ""
echo "🧪 Тест: 'Покажи файлы в /home/der'"
echo "Ожидаемо: список файлов + [🛠️mcp] + кнопки"
echo ""
echo "ЖДУ: результат."
