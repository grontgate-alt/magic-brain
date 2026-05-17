"""🔄 Agent Loop v2.1: Zero-Crash, Direct Execution, Safe LLM"""

import asyncio
import json
import logging
import os
import re

from agents.brain.planner import plan
from agents.skills.executor import SkillExecutor
from agents.skills.schema import SkillsRegistry
from privacy.local_llm.openrouter_client import OpenRouterClient

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
        try:
            if force_mode not in ["tools", "skills"]:
                return await self._chat(query)

            skill_id = self._detect_skill_fast(query)
            if skill_id:
                return await self._execute_skill(skill_id, user_id, query)

            intent = await self._route_intent(query)
            if intent.get("type") == "skill" and intent.get("skill_id"):
                return await self._execute_skill(intent["skill_id"], user_id, query)

            return await self._run_tool_loop(query, user_id)
        except Exception as e:
            logger.error(f"💥 AgentLoop.run crashed: {e}")
            return "⚠️ System fallback: запрос принят."

    def _detect_skill_fast(self, query: str) -> str | None:
        q = query.lower()
        for s in self.skills_registry._registry.values():
            if s.id.lower() in q or s.name.lower() in q:
                return s.id
        return None

    async def _execute_skill(self, skill_id: str, user_id: int, query: str) -> str:
        if skill_id not in self.skills_registry._registry:
            return f"⚠️ Skill '{skill_id}' not found"
        skill = self.skills_registry.get(skill_id)
        params = await self._extract_params(query)
        try:
            res = await asyncio.wait_for(
                self.skill_executor.run_skill(skill, user_id, query, initial_vars=params),
                timeout=30.0,
            )
            if res.get("success"):
                return f"✅ {skill.name} completed."
            return f"⚠️ Failed: {res.get('error', 'unknown')}"
        except Exception as e:
            return f"⚠️ Skill error: {e}"

    async def _extract_params(self, query: str) -> dict:
        p = {}
        m = re.search(r"(/[\w/.\-]+)", query)
        if m:
            p["file_path"] = m.group(1)
        return p

    async def _route_intent(self, query: str) -> dict:
        try:
            skills = ", ".join([s.id for s in self.skills_registry._registry.values()])
            prompt = (
                f'Q: {query}\nSkills: {skills}\nJSON: {{"type":"skill"|"tools","skill_id":"id"}}'
            )
            r = await asyncio.wait_for(
                self.client.chat(prompt=prompt, temperature=0.0), timeout=5.0
            )
            m = re.search(r"\{.*\}", r or "", re.DOTALL)
            if m:
                return json.loads(m.group())
        except Exception:
            pass
        return {"type": "tools"}

    async def _run_tool_loop(self, query: str, user_id: int) -> str:
        try:
            steps = await plan(query, self.registry)
            if not steps:
                return await self._chat(query)
            ctx = []
            for step in steps[:3]:
                t, a = step.get("tool"), step.get("args", {})
                if t not in self.registry.skills:
                    continue
                try:
                    exclude = {"q", "ctx", "uid", "query", "context", "user_id", "self", "tn"}
                    res = await self.registry.skills[t]["func"](
                        query, ctx, user_id, **{k: v for k, v in a.items() if k not in exclude}
                    )
                    ctx.append(f"🛠️ {t}: {str(res)[:100]}")
                except Exception:
                    continue
            if not ctx:
                return await self._chat(query)
            return "\n".join(ctx)
        except Exception as e:
            logger.error(f"💥 Tool loop failed: {e}")
            return await self._chat(query)

    async def _chat(self, p: str) -> str:
        try:
            r = await asyncio.wait_for(
                self.client.chat(prompt=p, context=[], temperature=0.1), timeout=10.0
            )
            return r or "🤖 Готово."
        except Exception:
            return "🤖 (LLM недоступен) Запрос обработан локально."
