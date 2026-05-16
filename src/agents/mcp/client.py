import asyncio, json, os, sys
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from typing import Dict, Any

class MCPAdapter:
    def __init__(self):
        self.tools_meta = {}
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

    async def connect_and_load(self):
        if self._tools_loaded: return self.tools_meta
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
                                "name": tname, "desc": tool.description or f"MCP:{name}",
                                "params": tool.inputSchema.get("properties", {}),
                                "privacy": "LOCAL" if name=="filesystem" else "CLOUD",
                                "server": name, "tool_name": tool.name
                            }
                print(f"✅ MCP {name}: {len([t for t in self.tools_meta if t.startswith(f'mcp_{name}')])} tools")
            except Exception as e:
                print(f"⚠️ MCP {name} load: {e}", file=sys.stderr)
        self._tools_loaded = True
        return self.tools_meta

    async def execute(self, tname: str, args: dict) -> str:
        if tname not in self.tools_meta:
            return f"⚠️ Tool not found: {tname}"
        meta = self.tools_meta[tname]
        cfg = self.server_configs[meta["server"]]
        tool_name = meta["tool_name"]

        try:
            params = StdioServerParameters(command=cfg["command"], args=cfg["args"], env={**os.environ, **cfg["env"]})
            # ✅ Прямое использование stdio_client как async context manager
            async with stdio_client(params) as (read, write):
                async with ClientSession(read, write) as session:
                    await session.initialize()
                    r = await session.call_tool(tool_name, args)
                    if not r or not hasattr(r, "content") or not r.content:
                        return "✅ Выполнено (нет данных)"
                    texts = []
                    for c in r.content:
                        if hasattr(c, "text") and c.text: texts.append(str(c.text))
                        elif hasattr(c, "data") and c.data: texts.append(str(c.data))
                        elif isinstance(c, str): texts.append(c)
                    result = "\n".join(texts).strip()
                    if not result: return "✅ Выполнено (пустой ответ)"
                    if len(result) > 4000: result = result[:3900] + "\n\n[... обрезано ...]"
                    return result
        except Exception as e:
            return f"⚠️ MCP {tool_name} error: {type(e).__name__}: {str(e)[:150]}"

mcp = MCPAdapter()
