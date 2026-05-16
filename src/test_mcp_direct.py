#!/usr/bin/env python3
import asyncio, sys, os
sys.path.insert(0, '/home/der/magic-brain')
os.environ.setdefault("QDRANT_HOST", "localhost")
os.environ.setdefault("QDRANT_PORT", "6333")

from agents.mcp.client import mcp

async def test():
    print("🔌 Подключаемся к MCP-серверам...")
    await mcp.connect_and_load()
    
    # ✅ FIX: tools_meta вместо tools
    print(f"\n📦 Доступно инструментов: {len(mcp.tools_meta)}")
    for name in list(mcp.tools_meta.keys())[:10]:
        print(f"  • {name}")
    
    # === ТЕСТ 1: list_directory /home/der ===
    print(f"\n🧪 ТЕСТ 1: list_directory /home/der")
    try:
        result = await mcp.execute("mcp_filesystem_list_directory", {"path": "/home/der"})
        print(f"✅ Ответ ({len(result)} симв.):")
        print(result[:500] + ("..." if len(result)>500 else ""))
    except Exception as e:
        print(f"❌ Ошибка: {e}")
        import traceback; traceback.print_exc()
    
    # === ТЕСТ 2: read_text_file ~/.env ===
    print(f"\n🧪 ТЕСТ 2: read_text_file ~/.env")
    try:
        env_path = os.path.expanduser("~/magic-brain/.env")
        result = await mcp.execute("mcp_filesystem_read_text_file", {"path": env_path})
        print(f"✅ Ответ ({len(result)} симв.):")
        print(result[:400] + ("..." if len(result)>400 else ""))
    except Exception as e:
        print(f"❌ Ошибка: {e}")
    
    # === ТЕСТ 3: github search ===
    print(f"\n🧪 ТЕСТ 3: github_search_repositories")
    try:
        result = await mcp.execute("mcp_github_search_repositories", {"query": "magic brain ai"})
        print(f"✅ Ответ ({len(result)} симв.):")
        print(result[:400] + ("..." if len(result)>400 else ""))
    except Exception as e:
        print(f"❌ Ошибка: {e}")

asyncio.run(test())
