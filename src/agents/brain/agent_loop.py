"""🔄 Agent Loop v2.0: Tools (v1) & Skills (v2)"""
import logging, os, json, re, asyncio
from agents.brain.planner import plan, replan
from agents.skills.schema import SkillsRegistry
from agents.skills.executor import SkillExecutor
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

        # 1. Быстрый детектор (мгновенно, без LLM)
        skill_id = self._detect_skill_fast(query)
        if skill_id:
            return await self._execute_skill(skill_id, user_id, query)

        # 2. LLM-роутинг (с жестким таймаутом 5с)
        intent = await self._route_intent(query)
        if intent.get("type") == "skill" and intent.get("skill_id"):
            return await self._execute_skill(intent["skill_id"], user_id, query)

        # 3. Fallback на v1 Tools
        logger.info("🛠️ Fallback to v1 Tool Planner")
        return await self._run_tool_loop(query, user_id)

    def _detect_skill_fast(self, query: str) -> str | None:
        """Детерминированный поиск скила по ID или имени в запросе."""
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
        params = await self._extract_params(query)
        try:
            res = await asyncio.wait_for(
                self.skill_executor.run_skill(skill, user_id, query, initial_vars=params),
                timeout=45.0
            )
            if res["success"]:
                return f"✅ {skill.name} completed."
            return f"⚠️ Skill failed: {res.get('error', 'unknown')}"
        except asyncio.TimeoutError:
            return "⏱️ Skill execution timeout"

    async def _extract_params(self, query: str) -> dict:
        p = {}
        paths = re.findall(r'(/[\w/.\-]+)', query)
        if paths:
            p["file_path"] = paths[0]
        return p

    async def _route_intent(self, query: str) -> dict:
        """LLM-роутер с защитой от зависаний."""
        try:
            skills = ", ".join([s.id for s in self.skills_registry._registry.values()])
            prompt = f"Query: {query}\nAvailable Skills: {skills}\nReturn JSON: {{\"type\": \"skill\"|\"tools\", \"skill_id\": \"id\"}}"
            r = await asyncio.wait_for(self.client.chat(prompt=prompt, temperature=0.0), timeout=5.0)
            m = re.search(r'\{.*\}', r, re.DOTALL)
            if m:
                return json.loads(m.group())
        except asyncio.TimeoutError:
            logger.warning("⏱️ LLM routing timeout, skipping")
        except Exception as e:
            logger.warning(f"⚠️ LLM routing failed: {e}")
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
                    res = await self.registry.skills[t]["func"](query, ctx, user_id, **{k: v for k, v in a.items() if k not in exclude})
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
        return await self._chat(f"Query: {query}\nResults:\n" + "\n".join(f"🛠️ {c['tool']}: {c['result']}" for c in ctx) + "\nSummarize.")

    async def _chat(self, p: str) -> str:
        try:
            return await self.client.chat(prompt=p, context=[])
        except Exception as e:
            logger.error(f"❌ Chat fail: {e}")
            return "⚠️ Error"
