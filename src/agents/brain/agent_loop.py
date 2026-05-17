"""🔄 Agent Loop v2.2: Production-Hardened, Zero-LLM-Block, Systemd-Ready"""

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

# 📢 Гарантированный вывод в stderr (systemd/journalctl)
logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stderr)],
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
            logger.warning(f"⚠️ Skills load failed: {e}")
        self.skill_executor = SkillExecutor()

    async def run(self, query: str, user_id: int = 1, force_mode: str = None) -> str:
        logger.info(f"📥 RUN: force={force_mode}, q='{query[:60]}'")
        try:
            if force_mode == "skills":
                sid = self._detect_skill_fast(query)
                if sid:
                    return await self._execute_skill(sid, user_id, query)
                return "⚠️ Скил не найден. Пример: 'запусти hello_world'"

            if force_mode == "tools":
                return await self._run_tool_loop(query, user_id)

            return await self._chat(query)
        except Exception:
            logger.exception("💥 CRASH in run()")
            return "⚠️ Внутренняя ошибка. Запрос записан в лог."

    def _detect_skill_fast(self, query: str) -> str | None:
        q = query.lower()
        for s in self.skills_registry._registry.values():
            if s.id.lower() in q or s.name.lower() in q:
                return s.id
        return None

    async def _execute_skill(self, skill_id: str, user_id: int, query: str) -> str:
        logger.info(f"🎯 Executing Skill: {skill_id}")
        if skill_id not in self.skills_registry._registry:
            return f"⚠️ Skill '{skill_id}' not found"
        skill = self.skills_registry.get(skill_id)
        params = {"file_path": m.group(1)} if (m := re.search(r"(/[\w/.\-]+)", query)) else {}
        try:
            res = await asyncio.wait_for(
                self.skill_executor.run_skill(skill, user_id, query, initial_vars=params),
                timeout=15.0,
            )
            return (
                f"✅ {skill.name} completed."
                if res.get("success")
                else f"⚠️ Failed: {res.get('error')}"
            )
        except TimeoutError:
            return "⏱️ Skill timeout (15s)"
        except Exception as e:
            return f"⚠️ Skill error: {e}"

    async def _run_tool_loop(self, query: str, user_id: int) -> str:
        try:
            steps = await asyncio.wait_for(plan(query, self.registry), timeout=10.0)
            if not steps:
                logger.warning("📋 Planner returned empty. Fallback to direct execution.")
                return await self._chat(query)

            ctx = []
            for step in steps[:3]:
                t, a = step.get("tool"), step.get("args", {})
                if t not in self.registry.skills:
                    continue
                try:
                    exclude = {"q", "ctx", "uid", "query", "context", "user_id", "self", "tn"}
                    func = self.registry.skills[t]["func"]
                    res = await asyncio.wait_for(
                        func(
                            query, ctx, user_id, **{k: v for k, v in a.items() if k not in exclude}
                        ),
                        timeout=10.0,
                    )
                    ctx.append(f"🛠️ {t}: {str(res)[:100]}")
                except Exception as e:
                    logger.error(f"❌ Tool {t} failed: {e}")
            return "\n".join(ctx) if ctx else await self._chat(query)
        except Exception as e:
            logger.error(f"💥 Tool loop failed: {e}")
            return await self._chat(query)

    async def _chat(self, p: str) -> str:
        if not self.client:
            return "🤖 LLM client unavailable."
        try:
            sig = inspect.signature(self.client.chat)
            kwargs = {"prompt": p}
            if "context" in sig.parameters:
                kwargs["context"] = []
            resp = await asyncio.wait_for(self.client.chat(**kwargs), timeout=10.0)
            return (resp or "").strip() or "🤖 Готово."
        except TimeoutError:
            return "⏱️ LLM timeout (10s)"
        except Exception as e:
            logger.warning(f"⚠️ LLM chat failed: {e}")
            return "🤖 (LLM недоступен) Локальная обработка завершена."


# 🔌 Backward compatibility for orchestrator.py
_default_loop = None


async def run(query: str, user_id: int = 1, force_mode: str = None, registry=None):
    global _default_loop
    if registry is None:
        from agents.brain.registry import registry as reg

        registry = reg
    if _default_loop is None or _default_loop.registry != registry:
        _default_loop = AgentLoop(registry)
    return await _default_loop.run(query, user_id, force_mode)
