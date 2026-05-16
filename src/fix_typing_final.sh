#!/bin/bash
set -e
cd ~/magic-brain

echo "[1/4] Фикс critic_loop.py: современные аннотации..."
cat << 'PY' > agents/brain/critic_loop.py
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
PY
echo "✅ critic_loop.py fixed"

echo "[2/4] Фикс worker.py: современные аннотации..."
cat << 'PY' > agents/brain/worker.py
import asyncio, time, re, os
from typing import Any

class Worker:
    def __init__(self, orchestrator):
        self.orch = orchestrator
        self.timeout = 60

    async def execute(self, step: dict, context: dict, user_id: int) -> dict[str, Any]:
        start = time.time()
        skill_name = step.get("skill")
        desc = step.get("desc", "")
        
        try:
            if skill_name and skill_name.startswith("mcp_"):
                args = self._parse_mcp_args(desc, skill_name)
                skill_meta = self.orch.registry.get(skill_name)
                if not skill_meta or not callable(skill_meta["func"]):
                    return {"success": False, "result": None, "error": f"Skill not found: {skill_name}", "duration": time.time() - start}
                
                raw_result = await asyncio.wait_for(
                    skill_meta["func"](desc, context, user_id, **args),
                    timeout=self.timeout
                )
                result = str(raw_result) if raw_result else "✅ Выполнено"
                return {"success": True, "result": result, "skill_used": skill_name, "duration": time.time() - start, "error": None}
            
            if skill_name:
                skill = self.orch.registry.get(skill_name)
                if skill and callable(skill["func"]):
                    args = {"query": desc, "context": context, "user_id": user_id}
                    raw = await asyncio.wait_for(skill["func"](**args), timeout=self.timeout)
                    result = str(raw) if raw else "✅ Выполнено"
                    return {"success": True, "result": result, "skill_used": skill_name, "duration": time.time() - start, "error": None}
            
            result = await self._fallback_llm(desc, context, user_id)
            return {"success": True, "result": result, "skill_used": "fallback_llm", "duration": time.time() - start, "error": None}
            
        except asyncio.TimeoutError:
            return {"success": False, "result": None, "error": f"timeout>{self.timeout}s", "duration": time.time() - start}
        except Exception as e:
            return {"success": False, "result": None, "error": f"{type(e).__name__}: {str(e)[:200]}", "duration": time.time() - start}
    
    def _parse_mcp_args(self, desc: str, tool_name: str) -> dict:
        args: dict = {}
        if "filesystem" in tool_name:
            paths = re.findall(r'(/[^\s,;"]+|~/[^\s,;"]+)', desc)
            if paths: args["path"] = paths[0]
            if "read" in tool_name and "path" not in args:
                args["path"] = os.path.expanduser("~")
        if "github" in tool_name:
            match = re.search(r'(?:репозиторий|поиск|запрос|про)\s+([^\s,;.!"]{3,})', desc, re.I)
            if match: args["query"] = match.group(1)
        if "query" not in args and "path" not in args:
            args["query"] = desc[:200]
        return args

    async def _fallback_llm(self, desc: str, context: dict, user_id: int) -> str:
        ctx_text = "\n".join(context.get("rag_results", [])[:3]) if context else ""
        prompt = f"Контекст:\n{ctx_text}\n\nЗадача: {desc}\n\nОтвет:"
        if hasattr(self.orch, 'local_llm'):
            return await self.orch.local_llm.chat(model="qwen2.5:3b", prompt=prompt, context=[])
        return f"[Выполнено: {desc[:50]}...]"
PY
echo "✅ worker.py fixed"

echo "[3/4] Проверка синтаксиса..."
python3 -m py_compile agents/brain/critic_loop.py && echo "✅ critic_loop.py OK"
python3 -m py_compile agents/brain/worker.py && echo "✅ worker.py OK"
python3 -m py_compile agents/main/orchestrator.py && echo "✅ orchestrator.py OK"

echo "[4/4] Перезапуск API..."
pkill -f uvicorn 2>/dev/null || true; sleep 3
set -a; source ~/magic-brain/.env; set +a
cd ~/magic-brain/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health && echo "✅ API UP" || echo "❌ API DOWN"

echo ""
echo "🧪 Тест (напиши боту в Telegram):"
echo "  • 'Покажи файлы в /home/der'"
echo ""
echo "ЖДУ: результат."
