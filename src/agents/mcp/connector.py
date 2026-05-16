"""
🔌 MCP Connector — минимальная реализация для загрузки инструментов
"""
import os, json, logging, asyncio, subprocess
from typing import Dict, List

class MCPConnector:
    def __init__(self, config_path: str = os.path.expanduser("~/.mcp/mcp.json")):
        self.config_path = config_path
        self._tools: List[Dict] = []
        self._loaded = False
        
    async def load_tools(self) -> List[Dict]:
        """Загружает инструменты из MCP-конфига"""
        if self._loaded:
            return self._tools
        if not os.path.exists(self.config_path):
            logging.warning(f"⚠️ MCP config not found: {self.config_path}")
            return []
        
        with open(self.config_path) as f:
            config = json.load(f)
        
        for name, cfg in config.get("mcpServers", {}).items():
            try:
                tools = await self._fetch_server(name, cfg)
                self._tools.extend(tools)
                logging.info(f"✅ MCP {name}: +{len(tools)} tools")
            except Exception as e:
                logging.warning(f"⚠️ MCP {name}: {e}")
        
        self._loaded = True
        logging.info(f"📦 MCP total: {len(self._tools)} tools")
        return self._tools
    
    async def _fetch_server(self, name: str, cfg: Dict) -> List[Dict]:
        """Получает список инструментов от сервера"""
        env = {**os.environ, **(cfg.get("env", {}))}
        # Заменяем ${VAR} на реальные значения
        for k, v in list(env.items()):
            if isinstance(v, str) and v.startswith("${") and v.endswith("}"):
                env[k] = os.getenv(v[2:-1], "")
        
        proc = await asyncio.create_subprocess_exec(
            cfg["command"], *cfg.get("args", []),
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE, env=env
        )
        
        request = json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}) + "\n"
        stdout, _ = await asyncio.wait_for(proc.communicate(input=request.encode()), timeout=15)
        
        tools = []
        try:
            resp = json.loads(stdout.decode().strip())
            for t in resp.get("result", {}).get("tools", []):
                tools.append({
                    "name": f"mcp_{name}_{t['name']}",
                    "desc": t.get("description", f"MCP: {t['name']}"),
                    "params": {k: {"type": v.get("type","string")} for k,v in t.get("inputSchema",{}).get("properties",{}).items()},
                    "func": lambda q,c,u,srv=name,tn=t["name"],**kw: {"ok":f"{srv}/{tn}"},
                    "privacy": "LOCAL" if name in ["filesystem","git","sqlite"] else "CLOUD",
                    "source": f"mcp:{name}"
                })
        except: pass
        await proc.wait()
        return tools

# Глобальный экземпляр
mcp = MCPConnector()
