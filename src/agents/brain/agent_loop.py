"""🔄 Agent Loop v2.0: Tools (v1) & Skills (v2)"""

import asyncio
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
        self.skills_registry = SkillsRegistry()
        self.skills_registry.load()
        self.skill_executor = SkillExecutor()

    async def run(self, query: str, user_id: int = 1, force_mode: str = None) -> str:
        if force_mode not in ["tools", "skills"]:
            return await self._chat(query)
        intent = await self._route_intent(query)

        if intent.get("type") == "skill" and intent.get("skill_id"):
            sid = intent["skill_id"]
            if sid in self.skills_registry._registry:
                logger.info(f"🧠 Routing to Skill: {sid}")
                params = await self._extract_params(query)
                try:
                    res = await asyncio.wait_for(
                        self.skill_executor.run_skill(
                            self.skills_registry.get(sid), user_id, query, initial_vars=params
                        ),
                        timeout=60.0,
                    )
                    return (
                        f"✅ {self.skills_registry.get(sid).name} completed."
                        if res["success"]
                        else f"⚠️ Failed: {res.get('error')}"
                    )
                except TimeoutError:
                    return "⏱️ Skill timeout"

        logger.info("🛠️ Fallback to v1 Tool Planner")
        return await self._run_tool_loop(query, user_id)

    async def _extract_params(self, query: str) -> dict:
        p = {}
        paths = re.findall(r"(/\S+)", query)
        if paths:
            p["file_path"] = paths[0]
        for k, v in re.findall(r"(\w+)[:=](\S+)", query):
            p[k.lower()] = v
        return p

    async def _route_intent(self, query: str) -> dict:
        skills = "\n".join(
            [f"- {s.id}: {s.description}" for s in self.skills_registry._registry.values()]
        )
        prompt = f"""Analyze: "{query}"
Available Skills: {skills or "None"}
Return JSON: {{"type": "skill"|"tools", "skill_id": "id_if_skill"}}"""
        try:
            r = await asyncio.wait_for(
                self.client.chat(prompt=prompt, temperature=0.1), timeout=15.0
            )
            m = re.search(r"\{.*\}", r, re.DOTALL)
            if m:
                return json.loads(m.group())
        except TimeoutError:
            logger.warning("⏱️ Routing timeout")
        except Exception as e:
            logger.warning(f"⚠️ Routing fail: {e}")
        return {"type": "tools"}

    async def _run_tool_loop(self, query: str, user_id: int) -> str:
        steps = await plan(query, self.registry)
        if not steps:
            return await self._chat(query)
        ctx = []
        for att in range(self.max_retries + 1):
            ok = True
            for step in steps:
                t, a = step.get("tool"), step.get("args", {})
                if t not in self.registry.skills:
                    ok = False
                    break
                try:
                    exclude = {"q", "ctx", "uid", "query", "context", "user_id", "self", "tn"}
                    res = await self.registry.skills[t]["func"](
                        query, ctx, user_id, **{k: v for k, v in a.items() if k not in exclude}
                    )
                    ctx.append({"tool": t, "result": str(res)[:500]})
                except Exception as e:
                    logger.error(f"❌ {t}: {e}")
                    ok = False
                    if att < self.max_retries:
                        steps = await replan(str(e), ctx, self.registry)
                    break
            if ok or not steps:
                break
        if not ctx:
            return await self._chat(query)
        return await self._chat(
            f"Query: {query}\nResults:\n"
            + "\n".join(f"🛠️ {c['tool']}: {c['result']}" for c in ctx)
            + "\nSummarize."
        )

    async def _chat(self, p: str) -> str:
        try:
            return await self.client.chat(prompt=p, context=[])
        except Exception as e:
            logger.error(f"❌ Chat fail: {e}")
            return "⚠️ Error"
