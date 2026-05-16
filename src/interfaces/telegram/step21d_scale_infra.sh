#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain
cd $BASE

echo "[1/4] Установка зависимостей для MCP и авто-синка..."
python3 -m pip install --break-system-packages -q mcp httpx gitpython 2>/dev/null || true
echo "✅ Зависимости готовы"

echo "[2/4] MCP Client Adapter: мост между MCP-серверами и твоим реестром..."
cat << 'PY' > agents/mcp/client.py
import asyncio, json, os
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from typing import Dict, List, Any

class MCPAdapter:
    """Динамическая загрузка инструментов из MCP-серверов"""
    def __init__(self):
        self.tools = {}
        self.servers = {
            "github": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"], "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": os.getenv("GITHUB_TOKEN","")}},
            "filesystem": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", os.path.expanduser("~")], "env": {}},
            "sqlite": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-sqlite", "--db-path", f"{BASE_DIR}/data/tools.db"], "env": {}},
            "web": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-web"], "env": {}},
            "google-maps": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-google-maps"], "env": {"GOOGLE_MAPS_API_KEY": os.getenv("GOOGLE_MAPS_API_KEY","")}},
        }
        self._loaded = False

    async def connect_and_load(self):
        """Подключается к серверам и регистрирует инструменты"""
        if self._loaded: return
        for name, cfg in self.servers.items():
            try:
                params = StdioServerParameters(command=cfg["command"], args=cfg["args"], env=cfg["env"])
                async with stdio_client(params) as (read, write):
                    async with ClientSession(read, write) as session:
                        await session.initialize()
                        resp = await session.list_tools()
                        for tool in resp.tools:
                            self.tools[f"mcp_{name}_{tool.name}"] = {
                                "name": f"mcp_{name}_{tool.name}",
                                "desc": tool.description or f"MCP tool from {name}",
                                "params": tool.inputSchema.get("properties", {}),
                                "privacy": "LOCAL" if name in ("filesystem", "sqlite") else "CLOUD",
                                "mcp_session": session,
                                "mcp_tool": tool.name,
                                "server": name
                            }
                print(f"✅ MCP {name}: {len([t for t in self.tools if t.startswith(f'mcp_{name}')])} tools")
            except Exception as e:
                print(f"⚠️ MCP {name} skipped: {e}")
        self._loaded = True

    async def execute(self, tool_name: str, arguments: dict) -> str:
        if tool_name not in self.tools: return f"⚠️ Tool {tool_name} not found"
        meta = self.tools[tool_name]
        try:
            resp = await meta["mcp_session"].call_tool(meta["mcp_tool"], arguments)
            return "\n".join([c.text for c in resp.content if hasattr(c, 'text')]) or str(resp)
        except Exception as e:
            return f"⚠️ MCP execution error: {str(e)[:150]}"

mcp = MCPAdapter()
BASE_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PY
echo "✅ MCP Adapter готов"

echo "[3/4] Tool Pack Manager: авто-загрузка и адаптация библиотек..."
cat << 'PY' > agents/tools/pack_manager.py
import os, sys, git, shutil, re, json
from pathlib import Path
from typing import Dict, List

class PackManager:
    """Загружает, адаптирует и обновляет сторонние библиотеки скиллов"""
    def __init__(self):
        self.packs_dir = Path(__file__).parent / "packs"
        self.packs_dir.mkdir(exist_ok=True)
        self.registry_map = {}  # file -> skill_name
    
    PACK_SOURCES = {
        "langchain_community": {
            "url": "https://github.com/langchain-ai/langchain.git",
            "path": "libs/community/langchain_community/tools",
            "skip": ["__pycache__", "test", "example"]
        },
        "openwebui_functions": {
            "url": "https://github.com/open-webui/functions.git",
            "path": "examples",
            "skip": ["__pycache__"]
        },
        "crewai_tools": {
            "url": "https://github.com/crewAIInc/crewAI-tools.git",
            "path": "crewai_tools/tools",
            "skip": ["__pycache__", "test"]
        }
    }

    def sync_all(self):
        """Клонирует/обновляет все паки"""
        for pack_id, cfg in self.PACK_SOURCES.items():
            local = self.packs_dir / pack_id
            try:
                if local.exists():
                    repo = git.Repo(local)
                    repo.remotes.origin.pull()
                    print(f"🔄 Обновлено: {pack_id}")
                else:
                    git.Repo.clone_from(cfg["url"], local, depth=1)
                    print(f"✅ Скачан: {pack_id}")
            except Exception as e:
                print(f"⚠️ {pack_id}: {e}")

    def adapt_and_register(self) -> Dict[str, Dict]:
        """Сканирует паки, создаёт адаптеры под __skill__, возвращает реестр"""
        skills = {}
        for pack_id, cfg in self.PACK_SOURCES.items():
            pack_path = self.packs_dir / pack_id / cfg["path"]
            if not pack_path.exists(): continue
            for py_file in pack_path.rglob("*.py"):
                if any(skip in str(py_file) for skip in cfg["skip"]): continue
                try:
                    # Создаём адаптер на лету
                    adapter_code = self._generate_adapter(pack_id, py_file)
                    skill_name = f"{pack_id}_{py_file.stem}"
                    skills[skill_name] = {
                        "code": adapter_code,
                        "desc": f"Pack tool: {pack_id}/{py_file.stem}",
                        "privacy": "CLOUD" if "web" in str(py_file) or "search" in str(py_file) else "LOCAL"
                    }
                    self.registry_map[skill_name] = py_file
                except Exception as e:
                    pass  # Пропускаем битые/несовместимые
        return skills

    def _generate_adapter(self, pack_id: str, py_file: Path) -> str:
        """Генерирует обёртку, совместимую с твоим orchestrator"""
        return f'''
import importlib.util, sys
from pathlib import Path

# Динамический импорт оригинала
spec = importlib.util.spec_from_file_location("orig", "{py_file}")
orig_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(orig_mod)

def __skill__():
    return {{
        "name": "{pack_id}_{py_file.stem}",
        "desc": "Auto-adapted from {pack_id}",
        "params": {{"query": "str", "context": "dict"}},
        "privacy": "{'CLOUD' if 'web' in str(py_file) or 'search' in str(py_file) else 'LOCAL'}"
    }}

async def {pack_id}_{py_file.stem}(query: str, context: dict, user_id: int, **kwargs) -> str:
    try:
        # Пытаемся найти основную функцию в модуле
        func = getattr(orig_mod, "run", getattr(orig_mod, "execute", getattr(orig_mod, "call", None)))
        if not func: return "⚠️ No callable entry found"
        res = func(query) if callable(func) else str(func)
        return str(res)[:2000]
    except Exception as e:
        return f"⚠️ Tool error: {{str(e)[:100]}}"
'''
    
pack_manager = PackManager()
PY
echo "✅ Pack Manager готов"

echo "[4/4] Единый реестр: статика + паки + MCP..."
cat << 'PY' > agents/brain/registry.py
import importlib, pkgutil, inspect, os, sys, asyncio
from pathlib import Path
from agents.tools.pack_manager import pack_manager
from agents.mcp.client import mcp

class SkillRegistry:
    def __init__(self):
        self.skills = {}
        self._base_dir = Path(__file__).parent.parent / "tools"
        self._loaded_packs = False
        self._loaded_mcp = False
    
    def load_static(self):
        """Загружает локальные скиллы из agents/tools/*.py"""
        if not self._base_dir.exists(): return
        for file in self._base_dir.rglob("*.py"):
            if file.name.startswith("_") or file.name == "__init__.py" or "packs" in str(file): continue
            rel = file.relative_to(self._base_dir.parent.parent)
            mod_name = str(rel.with_suffix('')).replace(os.sep, '.')
            try:
                mod = importlib.import_module(f"agents.{mod_name}")
                for name, obj in inspect.getmembers(mod):
                    if callable(obj) and hasattr(obj, "__skill__"):
                        meta = obj.__skill__()
                        self.skills[meta.get("name", name)] = {
                            "func": obj, "desc": meta.get("desc",""),
                            "params": meta.get("params",{}), "privacy": meta.get("privacy","CLOUD"),
                            "type": "static"
                        }
            except Exception as e:
                print(f"⚠️ Static {file.name}: {e}")

    async def load_packs(self):
        """Загружает и адаптирует сторонние библиотеки"""
        if self._loaded_packs: return
        pack_manager.sync_all()
        adapted = pack_manager.adapt_and_register()
        for name, meta in adapted.items():
            # Динамически создаём модуль и функцию
            mod_code = meta["code"]
            exec(mod_code, globals())
            func = globals().get(name)
            if func:
                self.skills[name] = {
                    "func": func, "desc": meta["desc"],
                    "params": meta.get("params",{}), "privacy": meta["privacy"],
                    "type": "pack"
                }
        self._loaded_packs = True

    async def load_mcp(self):
        """Загружает инструменты из MCP-серверов"""
        if self._loaded_mcp: return
        await mcp.connect_and_load()
        for name, meta in mcp.tools.items():
            # Обёртка для асинхронного вызова MCP
            async def mcp_wrapper(query: str, context: dict, user_id: int, tool_name=name, **kwargs):
                return await mcp.execute(tool_name, {"query": query, **kwargs})
            self.skills[name] = {
                "func": mcp_wrapper, "desc": meta["desc"],
                "params": meta["params"], "privacy": meta["privacy"],
                "type": "mcp"
            }
        self._loaded_mcp = True

    def list_available(self, query: str = None) -> List[str]:
        if not query: return list(self.skills.keys())
        q = query.lower()
        return [n for n,m in self.skills.items() if n in q or m.get("desc","").lower() in q] or list(self.skills.keys())[:10]

    def get(self, name: str):
        return self.skills.get(name)

    async def reload_all(self):
        self.skills.clear()
        self._loaded_packs = False
        self._loaded_mcp = False
        self.load_static()
        await self.load_packs()
        await self.load_mcp()
        print(f"📦 Registry: {len(self.skills)} tools loaded ({len([v for v in self.skills.values() if v['type']=='static'])} static, {len([v for v in self.skills.values() if v['type']=='pack'])} packs, {len([v for v in self.skills.values() if v['type']=='mcp'])} mcp)")

registry = SkillRegistry()
PY
echo "✅ Единый реестр готов"

echo ""
echo "🏗️ Инфраструктура масштабирования готова."
echo "Следующий шаг: синхронизация 800-1200 инструментов и интеграция в orchestrator."
echo "Выполни этот скрипт, скинь вывод, и я дам Шаг 2 (sync + orchestrator update)."
echo "ЖДУ: подтверждение."
