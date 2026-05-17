"""⚙️ Workflow Executor: Запускает YAML-скилы (v2.0 Logic)"""

import logging
from typing import Any

from jinja2 import Template

from agents.brain.registry import registry
from agents.skills.schema import SkillDefinition

logger = logging.getLogger(__name__)


class ExecutionError(Exception):
    pass


class ExecutionContext:
    """Хранит состояние выполнения: переменные, историю шагов."""

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
        entry = {
            "step_id": step_id,
            "tool": tool,
            "success": success,
            "result": str(result)[:500],  # Ограничиваем длину лога
        }
        self.history.append(entry)
        if success:
            # Авто-экспорт: результат шага 'foo' доступен как {{ foo_output }}
            if isinstance(result, str):
                self.set_var(f"{step_id}_output", result)
            elif isinstance(result, dict):
                for k, v in result.items():
                    self.set_var(f"{step_id}_{k}", v)


class SkillExecutor:
    """
    Исполнитель скилов.
    Берет SkillDefinition -> Итерирует шаги -> Рендерит аргументы -> Вызывает Tool.
    """

    def __init__(self):
        self.registry = registry

    async def run_skill(
        self, skill_def: SkillDefinition, user_id: int, query: str
    ) -> dict[str, Any]:
        ctx = ExecutionContext(user_id, query)
        logger.info(f"🚀 START Skill: {skill_def.name} ({skill_def.id})")

        for step in skill_def.steps:
            # 1. Проверка условия (например: "run_script.success == True")
            if step.condition:
                if not self._check_condition(step.condition, ctx):
                    logger.info(f"⏭️ Step '{step.id}' skipped (condition false)")
                    continue

            # 2. Рендер аргументов (например: "path: {{ file_path }}")
            rendered_args = self._render_args(step.args, ctx)
            tool_name = step.tool

            # 3. Поиск инструмента
            if tool_name not in self.registry.skills:
                err_msg = f"Tool '{tool_name}' not found in Registry"
                logger.error(f"❌ {err_msg}")
                ctx.log_step(step.id, tool_name, err_msg, False)
                if step.on_error == "abort":
                    return {"success": False, "error": err_msg, "history": ctx.history}
                continue

            # 4. Выполнение инструмента
            try:
                tool_func = self.registry.skills[tool_name]["func"]
                # Стандартная сигнатура наших инструментов: func(q, ctx_list, uid, **kwargs)
                # Мы передаем историю как context_list для совместимости, но в v2.0 она доступна через Jinja
                result = await tool_func(query, [], user_id, **rendered_args)
                ctx.log_step(step.id, tool_name, result, True)
                logger.info(f"✅ Step '{step.id}' OK")

            except Exception as e:
                logger.error(f"❌ Step '{step.id}' FAILED: {e}")
                ctx.log_step(step.id, tool_name, str(e), False)

                # Обработка ошибок
                if step.on_error == "abort":
                    return {"success": False, "error": str(e), "history": ctx.history}
                elif step.on_error == "retry":
                    logger.info(f"🔄 Retrying step '{step.id}'...")
                    try:
                        # Повторная попытка (рендер заново, вдруг переменные изменились)
                        new_args = self._render_args(step.args, ctx)
                        result = await tool_func(query, [], user_id, **new_args)
                        ctx.log_step(step.id, tool_name, result, True)
                    except Exception as retry_e:
                        logger.error(f"❌ Retry FAILED for '{step.id}': {retry_e}")
                        ctx.log_step(f"{step.id}_retry", tool_name, str(retry_e), False)
                        return {
                            "success": False,
                            "error": f"Retry failed: {retry_e}",
                            "history": ctx.history,
                        }
                # Если on_error == "skip", просто идем дальше

        logger.info(f"🏁 FINISH Skill: {skill_def.name}")
        return {"success": True, "result": ctx.variables, "history": ctx.history}

    def _check_condition(self, condition: str, ctx: ExecutionContext) -> bool:
        """Безопасный eval условий: 'step_x.success == True'"""
        try:
            # Собираем контекст для eval: переменные + история шагов
            # История доступна по ключу step_id: { "run_script": {"success": True, ...} }
            eval_ctx = dict(ctx.variables)
            for entry in ctx.history:
                eval_ctx[entry["step_id"]] = entry

            return bool(eval(condition, {"__builtins__": {}}, eval_ctx))
        except Exception as e:
            logger.warning(f"⚠️ Condition eval error: {e}")
            return False

    def _render_args(self, args: dict[str, Any], ctx: ExecutionContext) -> dict[str, Any]:
        """Рендер Jinja2 шаблонов в аргументах: '{{ query }}', '{{ file_path }}'"""
        rendered = {}
        for key, value in args.items():
            if isinstance(value, str) and "{{" in value:
                try:
                    t = Template(value)
                    # Пробрасываем все переменные и историю в шаблон
                    # История доступна как {{ run_script.output }} и т.д.
                    history_dict = {h["step_id"]: h for h in ctx.history}
                    rendered[key] = t.render(**ctx.variables, **history_dict)
                except Exception as e:
                    logger.warning(f"⚠️ Template render fail '{key}': {e}")
                    rendered[key] = value
            else:
                rendered[key] = value
        return rendered
