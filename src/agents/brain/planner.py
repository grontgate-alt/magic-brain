"""🧭 Planner v2.3: Strict JSON Tool Planning"""
import logging, json, re
from typing import List, Dict, Optional

logger = logging.getLogger(__name__)

# 🎯 Системный промпт: жёсткие правила
SYSTEM_PROMPT = """You are a tool planner. You MUST output STRICT JSON array of tool calls.
Available tools: write_file, execute_bash, web_search, read_file, smart_file_op.
Rules:
1. Return ONLY JSON array: [{"tool": "name", "args": {"key": "value"}}]
2. For file creation: use write_file with path and content
3. For poetry: use web_search first, then write_file
4. NEVER output markdown, explanations, or bash snippets — only JSON
5. If task is impossible, return []

Example for "create file with Pushkin poem":
[
  {"tool": "web_search", "args": {"query": "Пушкин Руслан и Людмила начало текст"}},
  {"tool": "write_file", "args": {"path": "/home/der/111.txt", "content": "{{search_result}}"}}
]
"""

async def plan(query: str, registry) -> List[Dict]:
    """Returns list of tool calls: [{"tool": "...", "args": {...}}]"""
    from privacy.local_llm.openrouter_client import OpenRouterClient
    
    client = OpenRouterClient(api_key=__import__('os').getenv("OPENROUTER_API_KEY"))
    if not client:
        logger.warning("⚠️ No LLM client, empty plan")
        return []
    
    tools_list = ", ".join([k for k in registry.skills.keys() if not k.startswith("_")])
    prompt = f"Task: {query}\nTools: {tools_list}\nReturn JSON array of tool calls."
    
    try:
        # Запрос с жёстким температурным контролем
        response = await client.chat(
            prompt=f"{SYSTEM_PROMPT}\n\nUser: {prompt}",
            temperature=0.0,  # Детерминированный вывод
            max_tokens=500
        )
        
        # Извлекаем JSON из ответа
        match = re.search(r'\[.*\]', response, re.DOTALL)
        if not match:
            logger.warning(f"⚠️ Planner: no JSON in response: {response[:100]}")
            return []
        
        plan_result = json.loads(match.group())
        if not isinstance(plan_result, list):
            logger.warning("⚠️ Planner: response is not array")
            return []
        
        # Валидация: каждый шаг должен иметь tool и args
        validated = []
        for step in plan_result:
            if isinstance(step, dict) and "tool" in step and "args" in step:
                if step["tool"] in registry.skills:
                    validated.append(step)
                else:
                    logger.warning(f"⚠️ Unknown tool: {step['tool']}")
        
        logger.info(f"🧭 Plan: {len(validated)} steps")
        return validated
        
    except Exception as e:
        logger.error(f"💥 Planner error: {e}")
        return []

async def replan(error: str, context: List, registry) -> List[Dict]:
    """Replan after error — упрощённая версия"""
    logger.warning(f"🔄 Replanning after: {error[:50]}")
    # Возвращаем пустой план — fallback на чат
    return []
