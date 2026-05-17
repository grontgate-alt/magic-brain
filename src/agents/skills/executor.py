"""⚙️ Workflow Executor: Запускает YAML-скилы (v2.0 Logic)"""

import logging
from typing import Any

from jinja2 import Template

from agents.brain.registry import registry
from agents.skills.schema import SkillDefinition

logger = logging.getLogger(__name__)


class ExecutionContext:
    def __init__(self, user_id: int, query: str, initial_vars: dict | None = None):
        self.user_id = user_id
        self.query = query
        self.variables: dict[str, Any] = {
            "user_id": user_id,
            "query": query,
            **(initial_vars or {}),
        }
        self.history: list[dict] = []

    def set_var(self, key: str, value: Any):
        self.variables[key] = value

    def log_step(self, step_id: str, tool: str, result: Any, success: bool):
        entry = {"step_id": step_id, "tool": tool, "success": success, "result": str(result)[:500]}
        self.history.append(entry)
        if success:
            if isinstance(result, str):
                self.set_var(f"{step_id}_output", result)
            elif isinstance(result, dict):
                for k, v in result.items():
                    self.set_var(f"{step_id}_{k}", v)


class SkillExecutor:
    def __init__(self):
        self.registry = registry

    async def run_skill(
        self,
        skill_def: SkillDefinition,
        user_id: int,
        query: str,
        initial_vars: dict | None = None,
    ) -> dict[str, Any]:
        ctx = ExecutionContext(user_id, query, initial_vars)
        logger.info(f"🚀 START Skill: {skill_def.name} ({skill_def.id})")
        for step in skill_def.steps:
            if step.condition and not self._check_condition(step.condition, ctx):
                logger.info(f"⏭️ Step '{step.id}' skipped")
                continue

            rendered_args = self._render_args(step.args, ctx)
            if step.tool not in self.registry.skills:
                err = f"Tool '{step.tool}' not found"
                logger.error(f"❌ {err}")
                ctx.log_step(step.id, step.tool, err, False)
                if step.on_error == "abort":
                    return {"success": False, "error": err, "history": ctx.history}
                continue

            success, result = await self._call_tool(step.tool, rendered_args, ctx)
            ctx.log_step(step.id, step.tool, result, success)

            if not success:
                if step.on_error == "abort":
                    return {"success": False, "error": result, "history": ctx.history}
                elif step.on_error == "retry":
                    for _ in range(step.max_retries):
                        s, r = await self._call_tool(step.tool, rendered_args, ctx)
                        if s:
                            ctx.log_step(step.id, step.tool, r, True)
                            break
                    else:
                        return {"success": False, "error": "Retry failed", "history": ctx.history}
        return {"success": True, "result": ctx.variables, "history": ctx.history}

    def _check_condition(self, cond: str, ctx: ExecutionContext) -> bool:
        try:
            safe_ctx = dict(ctx.variables)
            for h in ctx.history:
                safe_ctx[h["step_id"]] = h
            return bool(eval(cond, {"__builtins__": {}}, safe_ctx))
        except Exception as e:
            logger.warning(f"⚠️ Condition error: {e}")
            return False

    def _render_args(self, args: dict[str, Any], ctx: ExecutionContext) -> dict[str, Any]:
        rendered = {}
        for k, v in args.items():
            if isinstance(v, str) and "{{" in v:
                try:
                    rendered[k] = Template(v).render(
                        **ctx.variables, **{h["step_id"]: h for h in ctx.history}
                    )
                except Exception as e:
                    logger.warning(f"⚠️ Template fail '{k}': {e}")
                    rendered[k] = v
            else:
                rendered[k] = v
        return rendered

    async def _call_tool(
        self, tool_name: str, args: dict[str, Any], ctx: ExecutionContext
    ) -> tuple[bool, Any]:
        for k, v in args.items():
            if isinstance(v, str) and ("{{" in v or not v.strip()):
                return False, f"Missing arg '{k}' (Jinja unresolved)"
        try:
            func = self.registry.skills[tool_name]["func"]
            res = await func(ctx.query, ctx.history, ctx.user_id, **args)
            return True, res
        except Exception as e:
            return False, str(e)
