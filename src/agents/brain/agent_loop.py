import asyncio
import inspect
import logging
import os
import re
import sys

from agents.brain.planner import plan
from agents.skills.executor import SkillExecutor
from agents.skills.schema import SkillsRegistry
from privacy.local_llm.openrouter_client import OpenRouterClient

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stderr,
    force=True,
)
logger = logging.getLogger(__name__)


class AgentLoop:
    def __init__(self, registry):
        self.registry = registry
        self.client = OpenRouterClient(api_key=os.getenv("OPENROUTER_API_KEY"))
        self.skills_registry = SkillsRegistry()
        try:
            self.skills_registry.load()
        except Exception as e:
            logger.warning(f"⚠️ Skills load: {e}")
        self.skill_executor = SkillExecutor()

    async def run(self, query: str, user_id: int = 1, force_mode: str = None) -> str:
        logger.info(f"📥 RUN: mode={force_mode}, q='{query[:50]}...'")
        try:
            if force_mode == "skills":
                sid = self._detect_skill_fast(query)
                if sid:
                    return await self._execute_skill(sid, user_id, query)
                return "⚠️ Скил не найден. Доступны: " + ", ".join(
                    self.skills_registry._registry.keys()
                )
            if force_mode == "tools":
                return await self._run_tool_loop(query, user_id)
            return await self._chat(query)
        except Exception:
            logger.exception("💥 AgentLoop.run")
            return "⚠️ Ошибка обработки."

    def _detect_skill_fast(self, query: str) -> str | None:
        q = query.lower()
        for s in self.skills_registry._registry.values():
            if s.id.lower() in q or s.name.lower() in q:
                logger.info(f"🎯 Skill detected: {s.id}")
                return s.id
        return None

    async def _execute_skill(self, skill_id: str, user_id: int, query: str) -> str:
        logger.info(f"🚀 Executing Skill: {skill_id}")
        if skill_id not in self.skills_registry._registry:
            return f"⚠️ Skill '{skill_id}' not found"
        skill = self.skills_registry.get(skill_id)
        params = {"file_path": m.group(1)} if (m := re.search(r"(/[\w/.\-]+)", query)) else {}
        try:
            res = await asyncio.wait_for(
                self.skill_executor.run_skill(skill, user_id, query, initial_vars=params),
                timeout=20.0,
            )
            return (
                f"✅ {skill.name} completed."
                if res.get("success")
                else f"⚠️ Failed: {res.get('error', 'unknown')}"
            )
        except TimeoutError:
            return "⏱️ Skill timeout (20s)"
        except Exception as e:
            return f"⚠️ Error: {e}"

    async def _run_tool_loop(self, query: str, user_id: int) -> str:
    try:
        steps = await asyncio.wait_for(plan(query, self.registry), timeout=15.0)
        if not steps:
            logger.warning("📋 Empty plan, fallback to chat")
            return await self._chat(query)
        
        ctx = []
        for step in steps[:3]:  # максимум 3 шага
            tool_name = step.get("tool")
            args = step.get("args", {})
            
            if tool_name not in self.registry.skills:
                logger.warning(f"⚠️ Unknown tool in plan: {tool_name}")
                continue
            
            try:
                # Подготовка аргументов: рендер {{placeholders}} из контекста
                exclude = {"q", "ctx", "uid", "query", "context", "user_id", "self", "tn"}
                clean_args = {k: v for k, v in args.items() if k not in exclude}
                
                # Рендер Jinja-шаблонов в аргументах (если есть {{...}})
                from jinja2 import Template
                for k, v in clean_args.items():
                    if isinstance(v, str) and "{{" in v:
                        try:
                            clean_args[k] = Template(v).render(
                                **{f"ctx_{i}": c for i, c in enumerate(ctx)},
                                query=query
                            )
                        except:
                            pass  # оставляем как есть
                
                # Вызов инструмента
                func = self.registry.skills[tool_name]["func"]
                res = await asyncio.wait_for(
                    func(query, ctx, user_id, **clean_args),
                    timeout=20.0
                )
                ctx.append({"tool": tool_name, "result": str(res)[:300]})
                logger.info(f"✅ Tool {tool_name} executed")
                
            except Exception as e:
                logger.error(f"❌ Tool {tool_name} failed: {e}")
                # Продолжаем выполнение, не прерываем весь план
        
        # Формируем ответ из результатов выполнения
        if ctx:
            return "\n".join([f"🛠️ {c['tool']}: {c['result'][:100]}" for c in ctx])
        return await self._chat(query)
        
    except Exception as e:
        logger.error(f"💥 Tool loop crashed: {e}")
        return await self._chat(query)

    async def _chat(self, prompt: str) -> str:
        if not self.client:
            return "🤖 LLM unavailable."
        try:
            sig = inspect.signature(self.client.chat)
            kwargs = {"prompt": prompt}
            if "context" in sig.parameters:
                kwargs["context"] = []
            resp = await asyncio.wait_for(self.client.chat(**kwargs), timeout=30.0)
            return (resp or "").strip() or "🤖 Готово."
        except TimeoutError:
            return "⏱️ LLM timeout (30s)"
        except Exception as e:
            logger.warning(f"⚠️ LLM error: {e}")
            return "🤖 (LLM error) Запрос обработан."


_default_loop = None


async def run(query: str, user_id: int = 1, force_mode: str = None, registry=None):
    global _default_loop
    if registry is None:
        from agents.brain.registry import registry as reg

        registry = reg
    if _default_loop is None or _default_loop.registry != registry:
        _default_loop = AgentLoop(registry)
    return await _default_loop.run(query, user_id, force_mode)
