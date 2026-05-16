#!/bin/bash
set -e
cd ~/magic-brain

echo "[1/2] Фикс MCP Client: сессия на каждый вызов..."
cat << 'PY' > agents/mcp/client.py
import asyncio, json, os, re, sys
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from typing import Dict, List, Any, Optional

class MCPAdapter:
    def __init__(self):
        self.tools_meta = {}  # Только метаданные, без сессий
        self.server_configs = {
            "filesystem": {
                "command": "npx", 
                "args": ["-y", "@modelcontextprotocol/server-filesystem", os.path.expanduser("~")], 
                "env": {}
            },
            "github": {
                "command": "npx", 
                "args": ["-y", "@modelcontextprotocol/server-github"], 
                "env": {"GITHUB_TOKEN": os.getenv("GITHUB_TOKEN","")}
            },
        }
        self._tools_loaded = False

    async def _get_session(self, server_name: str):
        """Создаёт временную сессию для одного вызова"""
        cfg = self.server_configs.get(server_name)
        if not cfg:
            raise ValueError(f"Unknown server: {server_name}")
        params = StdioServerParameters(
            command=cfg["command"], 
            args=cfg["args"], 
            env={**os.environ, **cfg["env"]}
        )
        # Возвращаем контекстные менеджеры для использования снаружи
        return stdio_client(params)

    async def connect_and_load(self):
        """Загружает только метаданные инструментов (без сохранения сессий)"""
        if self._tools_loaded:
            return self.tools_meta
        
        for name, cfg in self.server_configs.items():
            try:
                params = StdioServerParameters(command=cfg["command"], args=cfg["args"], env={**os.environ, **cfg["env"]})
                async with stdio_client(params) as (read, write):
                    async with ClientSession(read, write) as session:
                        await session.initialize()
                        resp = await session.list_tools()
                        for tool in resp.tools:
                            tname = f"mcp_{name}_{tool.name}"
                            self.tools_meta[tname] = {
                                "name": tname, 
                                "desc": tool.description or f"MCP:{name}",
                                "params": tool.inputSchema.get("properties", {}),
                                "privacy": "LOCAL" if name=="filesystem" else "CLOUD",
                                "server": name,
                                "tool_name": tool.name
                            }
                print(f"✅ MCP {name}: {len([t for t in self.tools_meta if t.startswith(f'mcp_{name}')])} tools")
            except Exception as e:
                print(f"⚠️ MCP {name} load: {e}", file=sys.stderr)
        
        self._tools_loaded = True
        return self.tools_meta

    async def execute(self, tname: str, args: dict) -> str:
        """Выполняет инструмент, создавая временную сессию"""
        if tname not in self.tools_meta:
            return f"⚠️ Tool not found: {tname}"
        
        meta = self.tools_meta[tname]
        server = meta["server"]
        tool_name = meta["tool_name"]
        
        try:
            # Создаём НОВУЮ сессию для этого вызова
            async with self._get_session(server) as (read, write):
                async with ClientSession(read, write) as session:
                    await session.initialize()
                    r = await session.call_tool(tool_name, args)
                    
                    # === Устойчивый парсинг ответа ===
                    if not r or not hasattr(r, "content") or not r.content:
                        return "✅ Выполнено (нет данных)"
                    
                    texts = []
                    for c in r.content:
                        if hasattr(c, "text") and c.text:
                            texts.append(str(c.text))
                        elif hasattr(c, "data") and c.data:
                            texts.append(str(c.data))
                        elif isinstance(c, str):
                            texts.append(c)
                    
                    result = "\n".join(texts).strip()
                    if not result:
                        return "✅ Выполнено (пустой ответ)"
                    if len(result) > 4000:
                        result = result[:3900] + "\n\n[... обрезано ...]"
                    return result
                    
        except Exception as e:
            err = f"{type(e).__name__}: {str(e)[:150]}"
            return f"⚠️ MCP {tool_name} error: {err}"

# Глобальный экземпляр
mcp = MCPAdapter()
PY
echo "✅ MCP Client: сессия на вызов"

echo "[2/2] Фикс Registry: асинхронная инициализация..."
cat << 'PY' > agents/brain/registry.py
import importlib, pkgutil, inspect, os, sys, asyncio
from pathlib import Path
from agents.tools.pack_manager import pack_mgr
from agents.mcp.client import mcp

class SkillRegistry:
    def __init__(self):
        self.skills = {}
        self._base = Path(__file__).parent.parent / "tools"
        self._packs_loaded = False
        self._mcp_loaded = False
        self._mcp_init_done = False
    
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
                        self.skills[meta.get("n", n)] = {
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
        # Загружаем метаданные (без сессий)
        await mcp.connect_and_load()
        # Регистрируем обёртки для вызова
        for tname, meta in mcp.tools_meta.items():
            async def mcp_wrapper(query: str, context: dict, user_id: int, tn=tname, **kwargs):
                # Объединяем аргументы
                args = {"query": query, **kwargs}
                # Парсим путь если есть в запросе
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
        if not q: return list(self.skills.keys())
        ql = q.lower()
        return [n for n,m in self.skills.items() if n in ql or m.get("desc","").lower() in ql] or list(self.skills.keys())[:10]
    
    def get(self, n): return self.skills.get(n)
    
    async def reload(self):
        self.skills.clear()
        self._packs_loaded = False
        self._mcp_loaded = False
        self.load_static()
        await self.load_packs()
        await self.load_mcp()
        total = len(self.skills)
        types = {}
        for v in self.skills.values(): types[v['type']] = types.get(v['type'],0)+1
        print(f"📦 Registry: {total} tools ({types})")

registry = SkillRegistry()
PY
echo "✅ Registry: асинхронная загрузка"

echo "[3/3] Перезапуск API..."
pkill -f uvicorn 2>/dev/null || true; sleep 3
set -a; source ~/magic-brain/.env; set +a
cd ~/magic-brain/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health && echo "✅ API UP" || echo "❌ API DOWN"

echo ""
echo "🧪 Тест (напиши боту):"
echo "  • 'Покажи файлы в /home/der'"
echo "  • 'Прочитай ~/magic-brain/.env'"
echo ""
echo "Или запусти напрямую:"
echo "  python3 ~/magic-brain/test_mcp_direct.py"
echo ""
echo "ЖДУ: результат."
