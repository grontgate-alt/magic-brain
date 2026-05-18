# -*- coding: utf-8 -*-
import asyncio, inspect, logging, os, re, sys
from agents.brain.planner import plan
from agents.skills.executor import SkillExecutor
from agents.skills.schema import SkillsRegistry
from privacy.local_llm.openrouter_client import OpenRouterClient

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s", stream=sys.stderr, force=True)
logger = logging.getLogger(__name__)

class AgentLoop:
    def __init__(self, registry):
        self.registry = registry
        self.client = OpenRouterClient(api_key=os.getenv("OPENROUTER_API_KEY"))
        self.skills_registry = SkillsRegistry()
        try: self.skills_registry.load()
        except Exception as e: logger.warning(f"⚠️ Skills load: {e}")
        self.skill_executor = SkillExecutor()

    async def run(self, query: str, user_id: int = 1, force_mode: str = None) -> str:
        mode = force_mode or "tools"
        logger.info(f"📥 RUN: mode={mode}, q='{query[:50]}...'")
        try:
            if mode == "skills":
                sid = self._detect_skill_fast(query)
                if sid: return await self._execute_skill(sid, user_id, query)
                return "⚠️ Скил не найден."
            if mode == "tools":
                return await self._run_tool_loop(query, user_id)
            return await self._chat(query)
        except Exception:
            logger.exception("💥 AgentLoop.run crashed")
            return "⚠️ Внутренняя ошибка обработки."

    def _detect_skill_fast(self, query: str) -> str | None:
        q = query.lower()
        for s in self.skills_registry._registry.values():
            if s.id.lower() in q or s.name.lower() in q: return s.id
        return None

    async def _execute_skill(self, skill_id, user_id, query):
        if skill_id not in self.skills_registry._registry: return f"⚠️ Skill '{skill_id}' not found"
        skill = self.skills_registry.get(skill_id)
        params = {"file_path": m.group(1)} if (m := re.search(r"(/[\w/.\-]+)", query)) else {}
        try:
            res = await asyncio.wait_for(self.skill_executor.run_skill(skill, user_id, query, initial_vars=params), timeout=20.0)
            return f"✅ {skill.name} completed." if res.get("success") else f"⚠️ Failed: {res.get('error')}"
        except Exception as e: return f"⚠️ Error: {e}"

    async def _run_tool_loop(self, query: str, user_id: int) -> str:
        try:
            steps = await asyncio.wait_for(plan(query, self.registry), timeout=15.0)
            if not steps: return await self._chat(query)
            
            context_data = {}
            results = []
            
            for i, step in enumerate(steps[:3]):
                t, a = step.get("tool"), step.get("args", {})
                if t not in self.registry.skills: continue
                
                # Подстановка результатов предыдущих шагов
                final_args = {}
                for k, v in a.items():
                    if isinstance(v, str) and "{{" in v:
                        try:
                            from jinja2 import Template
                            final_args[k] = Template(v).render(**context_data)
                        except: final_args[k] = v
                    else: final_args[k] = v

                try:
                    func = self.registry.skills[t]["func"]
                    res = await asyncio.wait_for(func(query, [], user_id, **final_args), timeout=20.0)
                    context_data[f"step_{i}_result"] = str(res)
                    results.append(f"✅ {t} executed.")
                    logger.info(f"🛠️ Step {i} ({t}) success")
                except Exception as e:
                    logger.error(f"❌ Step {i} ({t}) failed: {e}")
                    results.append(f"❌ {t} failed.")
            
            return " | ".join(results) if results else await self._chat(query)
        except Exception as e:
            logger.error(f"💥 Tool loop crashed: {e}")
            return await self._chat(query)

    async def _chat(self, prompt: str) -> str:
        if not self.client: return "🤖 LLM unavailable."
        try:
            resp = await asyncio.wait_for(self.client.chat(prompt=prompt, temperature=0.7), timeout=30.0)
            return (resp or "").strip() or "🤖 Готово."
        except Exception as e: return f"🤖 (LLM error) {str(e)[:50]}"

# Backward compat
_default_loop = None
async def run(query: str, user_id: int = 1, force_mode: str = None, registry=None):
    global _default_loop
    if registry is None:
        from agents.brain.registry import registry as reg
        registry = reg
    if _default_loop is None or _default_loop.registry != registry:
        _default_loop = AgentLoop(registry)
    return await _default_loop.run(query, user_id, force_mode)
