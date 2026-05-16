import re
from typing import List, Tuple  # только то, что нужно импортировать

class CriticLoop:
    """Проверяет результат и при необходимости запускает ретрай"""
    
    MAX_RETRIES = 2
    CRITICAL_PATTERNS = [
        r'не могу|cannot|не удалось|error|ошибка',
        r'пусто|нет данных|nothing found',
        r'слишком длинный|too long|превышен',
    ]
    
    def validate(self, result: str, step_desc: str) -> tuple[bool, list[str]]:
        """Возвращает (ок, список проблем)"""
        issues: list[str] = []
        r = result.lower() if result else ""
        
        for pattern in self.CRITICAL_PATTERNS:
            if re.search(pattern, r, re.I):
                issues.append(f"refusal_or_error: {pattern}")
        
        if not result or len(result.strip()) < 10:
            issues.append("empty_response")
        
        if step_desc and len(step_desc) > 20:
            step_words = set(re.findall(r'[а-яa-z]{4,}', step_desc.lower()))
            result_words = set(re.findall(r'[а-яa-z]{4,}', r))
            overlap = len(step_words & result_words)
            if overlap < 2 and len(step_words) > 3:
                issues.append(f"low_relevance: overlap={overlap}")
        
        return len(issues) == 0, issues
    
    async def execute_with_retry(self, worker, step: dict, context: dict, user_id: int) -> dict:
        """Выполняет шаг с авто-ретраем при проблемах"""
        last_result = None
        
        for attempt in range(self.MAX_RETRIES + 1):
            result = await worker.execute(step, context, user_id)
            
            if not result["success"]:
                if attempt == self.MAX_RETRIES:
                    return result
                import asyncio
                await asyncio.sleep(1 * (attempt + 1))
                continue
            
            ok, issues = self.validate(result.get("result", ""), step.get("desc", ""))
            if ok:
                return result
            
            if attempt < self.MAX_RETRIES:
                context["_retry_info"] = {"attempt": attempt + 1, "issues": issues}
                context["_hint"] = f"Предыдущая попытка: {', '.join(issues)}. Попробуй полнее."
        
        return last_result or {"success": False, "error": "max_retries_exceeded"}
