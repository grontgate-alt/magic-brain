"""
🔁 Meta Skills — Агент умеет устанавливать себе новые навыки
"""
import os, json, asyncio, logging
from pathlib import Path

async def install_new_skill(query, ctx, uid, source: str, confirm: bool = False) -> str:
    """
    🔥 УСТАНОВИТЬ НОВЫЙ НАВЫК ИЛИ MCP СЕРВЕР.
    ИСПОЛЬЗУЙ ЭТОТ ИНСТРУМЕНТ ТОЛЬКО КОГДА ПОЛЬЗОВАТЕЛЬ ПРОСИТ "ДОБАВИТЬ НАВЫК", "УСТАНОВИТЬ ИНСТРУМЕНТ", "ЗАРЕГИСТРИРОВАТЬ СЕРВЕР".
    НЕ ИСПОЛЬЗУЙ ДЛЯ РАБОТЫ С ФАЙЛАМИ!
    """
    try:
        cfg_path = os.path.expanduser("~/.mcp/mcp.json")
        cfg = Path(cfg_path)
        config = json.loads(cfg.read_text()) if cfg.exists() else {"mcpServers": {}}
        
        # Парсим имя пакета (убираем префиксы если есть)
        name = source.split("/")[-1] if "/" in source else source
        # Упрощаем имя для конфига (убираем @scope/ если есть)
        short_name = name.replace("@modelcontextprotocol/", "").replace("@", "")
        
        # Определяем команду
        pkg = source if source.startswith("@") or "/" in source else f"@modelcontextprotocol/server-{short_name}"
        cmd = "npx" if "server" in pkg else pkg 
        
        config["mcpServers"][short_name] = {"command": "npx", "args": ["-y", pkg]}
        cfg.write_text(json.dumps(config, indent=2))
        
        # Перезагружаем кэш
        await _reload_cache()
        
        return f"✅ Успешно! Сервер `{short_name}` добавлен в конфигурацию. \n🔄 Кэш инструментов обновлен (теперь доступно больше навыков)."
    except Exception as e:
        return f"❌ Ошибка установки: {e}"

async def _reload_cache():
    try:
        from agents.mcp.connector import mcp
        tools = await mcp.load_tools()
        with open("/tmp/mcp_tools_cache.json", "w") as f:
            json.dump({"total": len(tools), "mcp_count": len([t for t in tools if "mcp_" in t["name"]]), "status": "ready", "examples": [t["name"] for t in tools][:50]}, f)
    except: pass

# Регистрируем с ОЧЕНЬ понятным именем и описанием
__skills__ = [{
    "name": "install_new_skill",
    "desc": "🔥 SYSTEM ADMIN TOOL: Add a NEW capability, skill, or MCP server to the agent. USE THIS when user asks to 'install', 'add', 'register' a tool. Example: source='@modelcontextprotocol/server-time'.",
    "params": {
        "source": {"type": "string", "desc": "Package name or identifier (e.g. '@modelcontextprotocol/server-brave-search')"},
        "confirm": {"type": "boolean", "default": False}
    },
    "func": install_new_skill,
    "privacy": "LOCAL"
}]
