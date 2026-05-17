"""⚙️ Workflow Executor: async state machine для композитных скилов."""

import asyncio
import logging
from typing import Any

from jinja2 import Template  # pip install jinja2

from agents.brain.registry import registry as tool_registry
from agents.skills.schema import SkillDefinition


class ExecutionContext:
    """Контекст выполнения скила: переменные, шаги, ошибки."""

    def __init__(self, user_id: int, query: str):
        self.user_id = user_id
        self.query = query
        self.variables: dict[str, Any] = {"query": query}
        self.step_results: dict[str, dict] = {}
        self.current_step: str | None = None
        self.error: str | None = None

    def get(self, key: str, default=None):
        """Доступ к переменным через {{ var }} в шаблонах."""
        return self.variables.get(key, default)

    def set(self, key: str, value: Any):
        self.variables[key] = value

    def step_done(self, step_id: str, result: Any, success: bool = True):
        self.step_results[step_id] = {
            "result": result,
            "success": success,
            "status": "ok" if success else "error",
        }
        if success and isinstance(result, (str, dict)):
            # Авто-экспорт результата в переменные для следующих шагов
            if isinstance(result, str) and len(result) < 200:
                self.variables[f"{step_id}_output"] = result
            elif isinstance(result, dict):
                for k, v in result.items():
                    self.variables[f"{step_id}_{k}"] = v


class WorkflowExecutor:
    """Исполнитель скилов: шаг за шагом, с условиями и восстановлением."""

    def __init__(self, timeout_sec: int = 120):
        self.timeout_sec = timeout_sec

    async def execute(self, skill: SkillDefinition, user_id: int, query: str) -> dict[str, Any]:
        """Запускает скил как state machine. Возвращает {success: bool, result: Any, error: str}."""
        ctx = ExecutionContext(user_id, query)
        try:
            return await asyncio.wait_for(self._run_steps(skill, ctx), timeout=self.timeout_sec)
        except TimeoutError:
            return {
                "success": False,
                "error": f"Timeout after {self.timeout_sec}s",
                "partial": ctx.step_results,
            }
        except Exception as e:
            logging.error(f"💥 Workflow crash: {e}")
            return {"success": False, "error": str(e), "partial": ctx.step_results}

    async def _run_steps(self, skill: SkillDefinition, ctx: ExecutionContext) -> dict[str, Any]:
        for step in skill.steps:
            ctx.current_step = step.id

            # 1. Проверка условия (Jinja-шаблон)
            if step.condition and not self._eval_condition(step.condition, ctx):
                logging.info(f"⏭️ Step {step.id} skipped (condition false)")
                continue

            # 2. Подготовка аргументов (рендер шаблонов)
            args = self._render_args(step.args, ctx)

            # 3. Выполнение инструмента
            success, result = await self._call_tool(step.tool, args, ctx)

            # 4. Обработка результата
            ctx.step_done(step.id, result, success)

            if not success:
                if step.on_error == "abort":
                    return {
                        "success": False,
                        "error": f"Step {step.id} failed",
                        "at": step.id,
                        "partial": ctx.step_results,
                    }
                elif step.on_error == "retry":
                    for attempt in range(step.max_retries):
                        logging.info(f"🔄 Retry {step.id} ({attempt + 1}/{step.max_retries})")
                        success, result = await self._call_tool(step.tool, args, ctx)
                        if success:
                            ctx.step_done(step.id, result, True)
                            break
                    if not success:
                        return {
                            "success": False,
                            "error": f"Step {step.id} failed after retries",
                            "at": step.id,
                            "partial": ctx.step_results,
                        }
                # on_error == "skip" → просто продолжаем

        # Успешное завершение
        final_result = (
            ctx.step_results.get(skill.steps[-1].id, {}).get("result") if skill.steps else None
        )
        return {"success": True, "result": final_result, "context": ctx.variables}

    def _eval_condition(self, condition: str, ctx: ExecutionContext) -> bool:
        """Простая оценка условий: 'step.status == "success"' или 'var > 10'."""
        try:
            # Безопасный eval через locals
            safe_globals = {"__builtins__": {}}
            safe_locals = {**{sid: sr for sid, sr in ctx.step_results.items()}, **ctx.variables}
            # Заменяем шаг.статус на доступный формат
            expr = condition.replace(".status", '["success"]').replace(".output", '["result"]')
            return bool(eval(expr, safe_globals, safe_locals))
        except Exception as e:
            logging.warning(f"⚠️ Condition eval failed '{condition}': {e}")
            return False

    def _render_args(self, args: dict[str, Any], ctx: ExecutionContext) -> dict[str, Any]:
        """Рендерит {{ var }} в аргументах через Jinja2."""
        rendered = {}
        for k, v in args.items():
            if isinstance(v, str) and "{{" in v:
                try:
                    rendered[k] = Template(v).render(
                        **ctx.variables, **{sid: sr for sid, sr in ctx.step_results.items()}
                    )
                except Exception as e:
                    logging.warning(f"⚠️ Template render failed for {k}: {e}")
                    rendered[k] = v
            else:
                rendered[k] = v
        return rendered

    async def _call_tool(
        self, tool_name: str, args: dict[str, Any], ctx: ExecutionContext
    ) -> tuple[bool, Any]:
        """Вызывает инструмент из registry. Возвращает (success, result)."""
        if tool_name not in tool_registry.skills:
            return False, f"Tool '{tool_name}' not found"
        try:
            func = tool_registry.skills[tool_name]["func"]
            # Универсальный вызов: все инструменты принимают (q, ctx, uid, **kwargs)
            result = await func(ctx.query, list(ctx.step_results.values()), ctx.user_id, **args)
            return True, result
        except Exception as e:
            logging.error(f"❌ Tool {tool_name} failed: {e}")
            return False, str(e)
