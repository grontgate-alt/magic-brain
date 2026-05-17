import asyncio
import os
import re
import time
from typing import Any


class Worker:
    def __init__(self, orchestrator):
        self.orch = orchestrator
        self.timeout = 60

    async def execute(self, step: dict, context: dict, user_id: int) -> dict[str, Any]:
        start = time.time()
        skill_name = step.get("skill")
        desc = step.get("desc", "")

        try:
            if skill_name and skill_name.startswith("mcp_"):
                args = self._parse_mcp_args(desc, skill_name)
                skill_meta = self.orch.registry.get(skill_name)
                if not skill_meta or not callable(skill_meta["func"]):
                    return {
                        "success": False,
                        "result": None,
                        "error": f"Skill not found: {skill_name}",
                        "duration": time.time() - start,
                    }

                raw_result = await asyncio.wait_for(
                    skill_meta["func"](desc, context, user_id, **args), timeout=self.timeout
                )
                result = str(raw_result) if raw_result else "✅ Выполнено"
                return {
                    "success": True,
                    "result": result,
                    "skill_used": skill_name,
                    "duration": time.time() - start,
                    "error": None,
                }

            if skill_name:
                skill = self.orch.registry.get(skill_name)
                if skill and callable(skill["func"]):
                    args = {"query": desc, "context": context, "user_id": user_id}
                    raw = await asyncio.wait_for(skill["func"](**args), timeout=self.timeout)
                    result = str(raw) if raw else "✅ Выполнено"
                    return {
                        "success": True,
                        "result": result,
                        "skill_used": skill_name,
                        "duration": time.time() - start,
                        "error": None,
                    }

            result = await self._fallback_llm(desc, context, user_id)
            return {
                "success": True,
                "result": result,
                "skill_used": "fallback_llm",
                "duration": time.time() - start,
                "error": None,
            }

        except TimeoutError:
            return {
                "success": False,
                "result": None,
                "error": f"timeout>{self.timeout}s",
                "duration": time.time() - start,
            }
        except Exception as e:
            return {
                "success": False,
                "result": None,
                "error": f"{type(e).__name__}: {str(e)[:200]}",
                "duration": time.time() - start,
            }

    def _parse_mcp_args(self, desc: str, tool_name: str) -> dict:
        args: dict = {}
        if "filesystem" in tool_name:
            paths = re.findall(r'(/[^\s,;"]+|~/[^\s,;"]+)', desc)
            if paths:
                args["path"] = paths[0]
            if "read" in tool_name and "path" not in args:
                args["path"] = os.path.expanduser("~")
        if "github" in tool_name:
            match = re.search(r'(?:репозиторий|поиск|запрос|про)\s+([^\s,;.!"]{3,})', desc, re.I)
            if match:
                args["query"] = match.group(1)
        if "query" not in args and "path" not in args:
            args["query"] = desc[:200]
        return args

    async def _fallback_llm(self, desc: str, context: dict, user_id: int) -> str:
        ctx_text = "\n".join(context.get("rag_results", [])[:3]) if context else ""
        prompt = f"Контекст:\n{ctx_text}\n\nЗадача: {desc}\n\nОтвет:"
        if hasattr(self.orch, "local_llm"):
            return await self.orch.local_llm.chat(model="qwen2.5:3b", prompt=prompt, context=[])
        return f"[Выполнено: {desc[:50]}...]"
