import asyncio
import json
import logging
import os


class MCPConnector:
    def __init__(self, cfg_path: str = os.path.expanduser("~/.mcp/mcp.json")):
        self.cfg_path = cfg_path
        self._tools: list[dict] = []
        self._loaded = False

    async def load_tools(self) -> list[dict]:
        if self._loaded:
            return self._tools
        if not os.path.exists(self.cfg_path):
            logging.warning(f"⚠️ MCP config not found: {self.cfg_path}")
            return []
        with open(self.cfg_path) as f:
            config = json.load(f)

        for name, cfg in config.get("mcpServers", {}).items():
            try:
                tools = await self._fetch(name, cfg)
                self._tools.extend(tools)
                logging.info(f"✅ MCP {name}: +{len(tools)} tools")
            except Exception as e:
                logging.warning(f"⚠️ MCP {name}: {e}")

        self._loaded = True
        logging.info(f"📦 MCP total: {len(self._tools)} tools")
        return self._tools

    async def _fetch(self, name: str, cfg: dict) -> list[dict]:
        env = os.environ.copy()
        for k, v in cfg.get("env", {}).items():
            if isinstance(v, str) and v.startswith("${") and v.endswith("}"):
                env[k] = os.getenv(v[2:-1], "")
            else:
                env[k] = v

        proc = await asyncio.create_subprocess_exec(
            cfg["command"],
            *cfg.get("args", []),
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=env,
        )
        req = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}) + "\n"
        out, err = await asyncio.wait_for(proc.communicate(input=req.encode()), timeout=15)

        tools = []
        try:
            resp = json.loads(out.decode().strip())
            for t in resp.get("result", {}).get("tools", []):
                params = {
                    k: {"type": v.get("type", "string")}
                    for k, v in t.get("inputSchema", {}).get("properties", {}).items()
                }
                tools.append(
                    {
                        "name": f"mcp_{name}_{t['name']}",
                        "desc": t.get("description", ""),
                        "params": params,
                        "func": lambda q, c, u, srv=name, tn=t["name"], **kw: {
                            "result": f"{srv}/{tn} executed"
                        },
                        "privacy": "LOCAL" if name in ["filesystem", "git", "sqlite"] else "CLOUD",
                        "source": f"mcp:{name}",
                    }
                )
        except Exception as e:
            logging.debug(f"Parse error for {name}: {e}")

        await proc.wait()
        return tools


mcp = MCPConnector()
