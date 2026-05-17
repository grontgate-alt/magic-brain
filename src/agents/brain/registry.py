"""♻️ Skill Registry: динамический лоадер + приоритет локальных паков над MCP"""

import asyncio
import importlib
import inspect
import logging
import os
from pathlib import Path


class SkillRegistry:
    def __init__(self):
        self.skills = {}
        self._base = Path(__file__).parent.parent / "tools"
        self._packs_loaded = False
        self._mcp_loaded = False
        self._ready = False
        self._init_lock = asyncio.Lock()

    def is_ready(self):
        return self._ready

    def load_static(self):
        if not self._base.exists():
            return
        for f in self._base.rglob("*.py"):
            if f.name.startswith("_") or "packs" in str(f):
                continue
            try:
                rel = f.relative_to(self._base.parent.parent)
                mod = importlib.import_module(
                    f"agents.{str(rel.with_suffix('')).replace(os.sep, '.')}"
                )
                for n, o in inspect.getmembers(mod):
                    if callable(o) and hasattr(o, "__skill__"):
                        m = o.__skill__()
                        self.skills[m.get("name", n)] = {
                            "func": o,
                            "desc": m.get("desc", ""),
                            "params": m.get("params", {}),
                            "privacy": m.get("privacy", "CLOUD"),
                            "type": "static",
                        }
            except:
                pass

    async def load_packs(self):
        if self._packs_loaded:
            return
        packs_dir = self._base / "packs"
        if not packs_dir.exists():
            return
        for f in sorted(packs_dir.glob("*.py")):
            if f.name.startswith("_"):
                continue
            mod_name = f"agents.tools.packs.{f.stem}"
            try:
                mod = importlib.import_module(mod_name)
                for s in getattr(mod, "__skills__", []):
                    self.skills[s["name"]] = s
                logging.info(f"✅ Pack {mod_name}: {len(getattr(mod, '__skills__', []))} loaded")
            except Exception as e:
                logging.warning(f"⚠️ Pack {mod_name}: {e}")
        self._packs_loaded = True

    async def load_mcp(self):
        if self._mcp_loaded:
            return
        try:
            from agents.mcp.client import mcp as mcp_client

            await mcp_client.connect_and_load()
            for tname, meta in mcp_client.tools_meta.items():
                # Локальные инструменты имеют ПРИОРИТЕТ. Не перезаписываем.
                if tname in self.skills:
                    logging.debug(f"⏭️ MCP {tname} skipped (local override)")
                    continue

                async def wrap(q, ctx, uid, tn=tname, **kw):
                    # Передаём только аргументы инструмента, без query
                    return await mcp_client.execute(tn, kw)

                self.skills[tname] = {
                    "func": wrap,
                    "desc": meta["desc"],
                    "params": meta["params"],
                    "privacy": meta["privacy"],
                    "type": "mcp",
                }
            self._mcp_loaded = True
            logging.info(f"✅ MCP loaded: {len(mcp_client.tools_meta)} tools")
        except Exception as e:
            logging.warning(f"⚠️ MCP load skipped: {e}")

    async def reload(self):
        async with self._init_lock:
            if self._ready:
                return
            self.skills.clear()
            self._packs_loaded = False
            self._mcp_loaded = False
            self.load_static()
            await self.load_packs()
            await self.load_mcp()
            self._ready = True
            print(f"✅ Registry loaded: {len(self.skills)} tools")

    def list(self, q=None):
        return list(self.skills.keys())

    def get(self, n):
        return self.skills.get(n)


registry = SkillRegistry()
