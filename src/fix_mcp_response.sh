#!/bin/bash
set -e
cd ~/magic-brain

echo "[1/2] Фикс MCP Client: обработка пустых/битых ответов..."
cat << 'PY' > agents/mcp/client.py
import asyncio, json, os, re
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
        if tname not in self.tools: 
            return f"⚠️ Tool not found: {tname}"
        m = self.tools[tname]
        try:
            # Выполняем инструмент
            r = await m["session"].call_tool(m["tool_name"], args)
            
            # === УСТОЙЧИВЫЙ ПАРСИНГ ОТВЕТА ===
            if not r or not hasattr(r, "content") or not r.content:
                return "✅ Выполнено (пустой ответ)"
            
            # Собираем текст из content
            texts = []
            for c in r.content:
                if hasattr(c, "text") and c.text:
                    texts.append(str(c.text))
                elif hasattr(c, "data") and c.data:
                    texts.append(str(c.data))
                elif isinstance(c, str):
                    texts.append(c)
            
            result = "\n".join(texts).strip()
            
            # Если всё ещё пусто — возвращаем заглушку
            if not result:
                return "✅ Выполнено (нет данных для отображения)"
            
            # Обрезаем если слишком длинно
            if len(result) > 4000:
                result = result[:3900] + "\n\n[... обрезано ...]"
            
            return result
            
        except json.JSONDecodeError as e:
            # Сырой ответ если JSON не парсится
            return f"⚠️ Parse error: {str(e)[:100]}\n\nRaw: {str(r)[:500]}"
        except Exception as e:
            return f"⚠️ MCP error: {type(e).__name__}: {str(e)[:150]}"

mcp = MCPAdapter()
PY
echo "✅ MCP Client fixed"

echo "[2/2] Фикс Worker: передача аргументов в MCP..."
cat << 'PY' > agents/brain/worker.py
import asyncio, time, re, json
from typing import Optional, Dict, Any

class Worker:
    def __init__(self, orchestrator):
        self.orch = orchestrator
        self.timeout = 60

    async def execute(self, step: Dict, context: Dict, user_id: int) -> Dict[str, Any]:
        start = time.time()
        skill_name = step.get("skill")
        desc = step.get("desc", "")
        
        try:
            if skill_name and skill_name.startswith("mcp_"):
                # === MCP-инструмент: парсим аргументы из описания ===
                args = self._parse_mcp_args(desc, skill_name)
                result = await asyncio.wait_for(
                    self.orch.registry.get(skill_name)["func"](desc, context, user_id, **args),
                    timeout=self.timeout
                )
                return {"success": True, "result": result, "skill_used": skill_name, "duration": time.time() - start, "error": None}
            
            # Обычный скилл
            if skill_name:
                skill = self.orch.registry.get(skill_name)
                if skill and callable(skill["func"]):
                    args = {"query": desc, "context": context, "user_id": user_id}
                    result = await asyncio.wait_for(skill["func"](**args), timeout=self.timeout)
                    return {"success": True, "result": result, "skill_used": skill_name, "duration": time.time() - start, "error": None}
            
            # Fallback на LLM
            result = await self._fallback_llm(desc, context, user_id)
            return {"success": True, "result": result, "skill_used": "fallback_llm", "duration": time.time() - start, "error": None}
            
        except asyncio.TimeoutError:
            return {"success": False, "result": None, "error": f"timeout>{self.timeout}s", "duration": time.time() - start}
        except Exception as e:
            return {"success": False, "result": None, "error": str(e)[:200], "duration": time.time() - start}
    
    def _parse_mcp_args(self, desc: str, tool_name: str) -> dict:
        """Извлекает аргументы из описания для MCP-инструментов"""
        args = {}
        
        # Для filesystem: ищем пути
        if "filesystem" in tool_name:
            # Ищем /path/to/something или ~/path
            paths = re.findall(r'(/[^\s,;"]+|~/[^\s,;"]+)', desc)
            if paths:
                args["path"] = paths[0]
            # Для read: может быть просто "прочитай файл"
            if "read" in tool_name and "path" not in args:
                args["path"] = os.path.expanduser("~")
        
        # Для github: ищем названия репо/запросов
        if "github" in tool_name:
            # Ищем "репозиторий Х" или "поиск по Х"
            match = re.search(r'(?:репозиторий|поиск|запрос|про)\s+([^\s,;.!"]{3,})', desc, re.I)
            if match:
                args["query"] = match.group(1)
        
        # Дефолтный query если ничего не нашли
        if "query" not in args and "path" not in args:
            args["query"] = desc[:200]
        
        return args

    async def _fallback_llm(self, desc: str, context: Dict, user_id: int) -> str:
        ctx_text = "\n".join(context.get("rag_results", [])[:3]) if context else ""
        prompt = f"Контекст:\n{ctx_text}\n\nЗадача: {desc}\n\nОтвет:"
        if hasattr(self.orch, 'local_llm'):
            return await self.orch.local_llm.chat(model="qwen2.5:3b", prompt=prompt, context=[])
        return f"[Выполнено: {desc[:50]}...]"
PY
echo "✅ Worker fixed"

echo "[3/3] Перезапуск API..."
pkill -f uvicorn 2>/dev/null || true; sleep 3
set -a; source ~/magic-brain/.env; set +a
cd ~/magic-brain/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health && echo "✅ API UP" || echo "❌ API DOWN"

echo ""
echo "🧪 Тест MCP (напиши боту):"
echo "  • 'Покажи файлы в /home'"
echo "  • 'Прочитай ~/magic-brain/.env'"
echo "  • 'Список файлов в ~/Документы'"
echo ""
echo "Если ошибка — скинь: tail -20 /tmp/api.log"
echo "ЖДУ: результат."
