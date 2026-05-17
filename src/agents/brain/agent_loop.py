"""🔄 Agent Loop v2.0: Supports Tools (v1) & Skills (v2 Workflow Engine)"""

import json
import logging
import os
import re

from agents.brain.planner import plan, replan
from agents.skills.executor import SkillExecutor
from agents.skills.schema import SkillsRegistry
from privacy.local_llm.openrouter_client import OpenRouterClient

logger = logging.getLogger(__name__)


class AgentLoop:
    def __init__(self, registry):
        self.registry = registry
        self.max_retries = 2
        self.client = OpenRouterClient(api_key=os.getenv("OPENROUTER_API_KEY"))

        # v2.0: Инициализация реестра скилов
        self.skills_registry = SkillsRegistry()
        self.skills_registry.load()
        self.skill_executor = SkillExecutor()

    async def run(self, query: str, user_id: int = 1, force_mode: str = None) -> str:
        # 1. Чат-режим по умолчанию
        if force_mode not in ["tools", "skills"]:
            return await self._chat(query)

        # 2. Маршрутизация: LLM решает Skill или Tool
        intent = await self._route_intent(query)

        # 3. v2.0: Выполнение скила
        if intent.get("type") == "skill" and intent.get("skill_id"):
            skill_id = intent["skill_id"]
            if skill_id in self.skills_registry._registry:
                logger.info(f"🧠 Routing to Skill: {skill_id}")
                skill_def = self.skills_registry.get(skill_id)
                res = await self.skill_executor.run_skill(skill_def, user_id, query)
                if res["success"]:
                    return f"✅ {skill_def.name} completed."
                return f"⚠️ Skill failed: {res.get('error', 'unknown')}"

        # 4. Fallback v1.0: Планировщик инструментов
        logger.info("🛠️ Routing to v1 Tool Planner")
        return await self._run_tool_loop(query, user_id)

    async def _route_intent(self, query: str) -> dict:
        skills_list = "\n".join(
            [f"- {s.id}: {s.description}" for s in self.skills_registry._registry.values()]
        )
        prompt = f"""Analyze: "{query}"
Available Skills: {skills_list or "None"}
Return STRICT JSON: {{"type": "skill"|"tools"|"chat", "skill_id": "id_if_skill"}}"""
        try:
            resp = await self.client.chat(prompt=prompt, temperature=0.1)
            m = re.search(r"\{.*\}", resp, re.DOTALL)
            if m:
                return json.loads(m.group())
        except Exception as e:
            logger.warning(f"⚠️ Intent routing failed: {e}")
        return {"type": "tools"}

    async def _run_tool_loop(self, query: str, user_id: int) -> str:
        steps = await plan(query, self.registry)
        if not steps:
            return await self._chat(query)

        context = []
        for attempt in range(self.max_retries + 1):
            success = True
            for step in steps:
                tool_name = step.get("tool")
                args = step.get("args", {})
                if tool_name not in self.registry.skills:
                    success = False
                    break
                try:
                    func = self.registry.skills[tool_name]["func"]
                    exclude = {"q", "ctx", "uid", "query", "context", "user_id", "self", "tn"}
                    tool_args = {k: v for k, v in args.items() if k not in exclude}
                    res = await func(query, context, user_id, **tool_args)
                    context.append({"tool": tool_name, "result": str(res)[:500]})
                except Exception as e:
                    logger.error(f"❌ {tool_name}: {e}")
                    success = False
                    if attempt < self.max_retries:
                        steps = await replan(str(e), context, self.registry)
                    break
            if success or not steps:
                break

        if not context:
            return await self._chat(query)
        summary = "\n".join([f"🛠️ {c['tool']}: {c['result']}" for c in context])
        return await self._chat(f"Query: {query}\nResults:\n{summary}\nSummarize for user.")

    async def _chat(self, prompt: str) -> str:
        try:
            return await self.client.chat(prompt=prompt, context=[])
        except Exception as e:
            logger.error(f"❌ Chat fallback failed: {e}")
            return "⚠️ Processing error."
