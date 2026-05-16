#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"

# 🔑 Жёсткая привязка к корню проекта
BASE=~/magic-brain
cd "$BASE"
mkdir -p agents/mcp agents/tools/packs

echo "📍 Рабочая папка: $(pwd)"
echo "[1/4] Зависимости..."
python3 -m pip install --break-system-packages -q mcp httpx gitpython 2>/dev/null || true
echo "✅ Зависимости"

echo "[2/4] MCP Adapter..."
cat << 'PY' > agents/mcp/client.py
import asyncio, json, os
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from typing import Dict, List, Any

class MCPAdapter:
    def __init__(self):
        self.tools = {}
        self.servers = {
            "filesystem": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", os.path.expanduser("~")], "env": {}},
            "github": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"], "env": {"GITHUB_TOKEN": os.getenv("GITHUB_TOKEN","")}},
        }
        self._loaded = False

    async def connect_and_load(self):
        if self._loaded: return
        for name, cfg in self.servers.items():
            try:
                params = StdioServerParameters(command=cfg["command"], args=cfg["args"], env=cfg["env"])
                async with stdio_client(params) as (read, write):
                    async with ClientSession(read, write) as session:
                        await session.initialize()
                        resp = await session.list_tools()
                        for tool in resp.tools:
                            tname = f"mcp_{name}_{tool.name}"
                            self.tools[tname] = {
                                "name": tname, "desc": tool.description or f"MCP:{name}",
                                "params": tool.inputSchema.get("properties", {}),
                                "privacy": "LOCAL" if name=="filesystem" else "CLOUD",
                                "session": session, "tool_name": tool.name
                            }
                print(f"✅ MCP {name}: {len([t for t in self.tools if t.startswith(f'mcp_{name}')])} tools")
            except Exception as e:
                print(f"⚠️ MCP {name}: {e}")
        self._loaded = True

    async def execute(self, tname: str, args: dict) -> str:
        if tname not in self.tools: return f"⚠️ Not found"
        m = self.tools[tname]
        try:
            r = await m["session"].call_tool(m["tool_name"], args)
            return "\n".join([c.text for c in r.content if hasattr(c,'text')]) or str(r)
        except Exception as e:
            return f"⚠️ MCP err: {str(e)[:150]}"

mcp = MCPAdapter()
PY
echo "✅ MCP Adapter"

echo "[3/4] Pack Manager..."
cat << 'PY' > agents/tools/pack_manager.py
import os, sys, git, re
from pathlib import Path

class PackManager:
    def __init__(self):
        self.dir = Path(__file__).parent / "packs"
        self.dir.mkdir(exist_ok=True)
        self.sources = {
            "langchain": {"url": "https://github.com/langchain-ai/langchain.git", "path": "libs/community/langchain_community/tools"},
            "openwebui": {"url": "https://github.com/open-webui/functions.git", "path": "examples"},
        }
    def sync(self):
        for pid, cfg in self.sources.items():
            local = self.dir / pid
            try:
                if local.exists():
                    git.Repo(local).remotes.origin.pull()
                    print(f"🔄 {pid} updated")
                else:
                    git.Repo.clone_from(cfg["url"], local, depth=1)
                    print(f"✅ {pid} cloned")
            except Exception as e: print(f"⚠️ {pid}: {e}")
    def adapt(self):
        skills = {}
        for pid, cfg in self.sources.items():
            p = self.dir / pid / cfg["path"]
            if not p.exists(): continue
            for f in p.rglob("*.py"):
                if "__" in f.name or "test" in str(f): continue
                try:
                    skills[f"{pid}_{f.stem}"] = {
                        "desc": f"Pack:{pid}", "privacy": "CLOUD" if "web" in str(f) or "search" in str(f) else "LOCAL",
                        "code": f'''
import importlib.util, sys
spec = importlib.util.spec_from_file_location("m", "{f}")
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
def __skill__(): return {{"name":"{pid}_{f.stem}","desc":"Auto:{pid}","params":{{}},"privacy":"{'CLOUD' if 'web' in str(f) or 'search' in str(f) else 'LOCAL'}"}}
async def {pid}_{f.stem}(q, ctx, uid, **kw):
    try:
        fn = getattr(mod, "run", getattr(mod, "execute", None))
        return str(fn(q) if fn else mod)[:2000]
    except Exception as e: return f"⚠️ {{e}}"
'''
                    }
                except: pass
        return skills
pack_mgr = PackManager()
PY
echo "✅ Pack Manager"

echo "[4/4] Unified Registry..."
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
                        self.skills[meta.get("n", n)] = {"func": o, "desc": meta.get("desc",""), "params": meta.get("params",{}), "privacy": meta.get("privacy","CLOUD"), "type": "static"}
            except: pass
    async def load_packs(self):
        if self._packs_loaded: return
        pack_mgr.sync()
        for n, m in pack_mgr.adapt().items():
            exec(m["code"], globals())
            fn = globals().get(n)
            if fn: self.skills[n] = {"func": fn, "desc": m["desc"], "params": {}, "privacy": m["privacy"], "type": "pack"}
        self._packs_loaded = True
    async def load_mcp(self):
        if self._mcp_loaded: return
        await mcp.connect_and_load()
        for n, m in mcp.tools.items():
            async def wrap(q, ctx, uid, tn=n, **kw): return await mcp.execute(tn, {"query": q, **kw})
            self.skills[n] = {"func": wrap, "desc": m["desc"], "params": m["params"], "privacy": m["privacy"], "type": "mcp"}
        self._mcp_loaded = True
    def list(self, q=None):
        if not q: return list(self.skills.keys())
        ql = q.lower()
        return [n for n,m in self.skills.items() if n in ql or m.get("desc","").lower() in ql] or list(self.skills.keys())[:10]
    def get(self, n): return self.skills.get(n)
    async def reload(self):
        self.skills.clear(); self._packs_loaded=False; self._mcp_loaded=False
        self.load_static(); await self.load_packs(); await self.load_mcp()
        print(f"📦 {len(self.skills)} tools ({sum(1 for v in self.skills.values() if v['type']=='static')} static, {sum(1 for v in self.skills.values() if v['type']=='pack')} packs, {sum(1 for v in self.skills.values() if v['type']=='mcp')} mcp)")
registry = SkillRegistry()
PY
echo "✅ Registry"

echo ""
echo "🏗️ Инфраструктура готова. Жду ОК для Шага 2 (sync 800+ tools + orchestrator update)."
