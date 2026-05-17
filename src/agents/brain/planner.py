"""🧠 Планировщик: строгий JSON, пост-валидация имён, 0 hallucination"""
import os, json, re, logging, inspect
from typing import List, Tuple, Dict, Any
from privacy.local_llm.openrouter_client import OpenRouterClient
from agents.brain.tool_db import get_routes, get_tools_by_route

async def _call_openrouter(prompt: str) -> str:
    client = OpenRouterClient(api_key=os.getenv("OPENROUTER_API_KEY"))
    sig = inspect.signature(client.chat)
    allowed = set(sig.parameters.keys()) - {'self'}
    kwargs = {"prompt": prompt, "context": [], "temperature": 0.0}
    extra = {"response_format": {"type": "json_object"}}
    for k, v in extra.items():
        if k in allowed: kwargs[k] = v
    try: return await client.chat(**kwargs)
    except Exception as e:
        logging.error(f"❌ OpenRouter: {e}")
        return "{}"

def _extract_json(text: str) -> Dict[str, Any]:
    if not text or not isinstance(text, str): return {}
    patterns = [
        r'```(?:json)?\s*(\{.*?\})\s*```',
        r'(\{[\s\S]*"steps"[\s\S]*\})',
        r'(\{[\s\S]*"route"[\s\S]*\})',
        r'(\{.*\})'
    ]
    for p in patterns:
        m = re.search(p, text, re.DOTALL)
        if m:
            try:
                res = json.loads(m.group(1) if m.lastindex else m.group(0))
                if isinstance(res, dict): return res
            except: continue
    return {}

async def plan(query: str, registry) -> List[Dict]:
    routes: List[Tuple[str, str]] = get_routes()
    if not routes: return []

    # 1. Выбор маршрута
    route_hints = "\n".join([f"- {r[0]}: {r[1]}" for r in routes])
    p1 = f"""Ты — роутер. Запрос: {query}
Доступные категории:
{route_hints}
Выбери ОДНУ. Верни строго JSON: {{"route": "domain/category/subcategory"}}"""
    try:
        r1 = await _call_openrouter(p1)
        data1 = _extract_json(r1)
        selected = data1.get("route") if isinstance(data1, dict) else None
        valid_routes = [r[0] for r in routes]
        if not selected or selected not in valid_routes: selected = routes[0][0]
        logging.info(f"🧭 Intent Route: {selected}")
    except Exception as e:
        logging.warning(f"⚠️ Route fallback: {e}")
        selected = routes[0][0]

    # 2. Инструменты
    tools = get_tools_by_route(selected)
    if not tools:
        fb = next((r[0] for r in routes if r[0] != selected), routes[0][0])
        tools = get_tools_by_route(fb)

    tool_names = [t["name"] for t in tools]
    
    # 3. Планирование (анти-галлюцинационный промпт)
    p2 = f"""Запрос: {query}
Доступные инструменты: {tool_names}
Схема: {json.dumps(tools, ensure_ascii=False, indent=2)}
Верни строго JSON: {{"steps": [{{"tool": "ИМЯ_ИЗ_СПИСКА_ВЫШЕ", "args": {{...}}}}]}}
ВАЖНО: Не выдумывай названия. Используй ТОЛЬКО то, что есть в списке "Доступные инструменты"."""

    try:
        r2 = await _call_openrouter(p2)
        data2 = _extract_json(r2)
        if not isinstance(data2, dict): return []
        steps = data2.get("steps", [])
        if not isinstance(steps, list): return []
        
        # ЖЁСТКАЯ ВАЛИДАЦИЯ: оставляем только шаги с реальными именами
        valid_steps = [s for s in steps if isinstance(s, dict) and s.get("tool") in tool_names]
        
        if valid_steps:
            logging.info(f"📋 Plan parsed: {[s.get('tool') for s in valid_steps]}")
            return valid_steps
        logging.warning(f"⚠️ LLM hallucinated tool names. Returned: {[s.get('tool') for s in steps]}")
        return []
    except Exception as e:
        logging.error(f"💥 Plan: {e}")
        return []

async def replan(error: str, context: list, registry) -> List[Dict]:
    available = list(registry.skills.keys())
    try:
        p = f"""Шаг упал. Ошибка: {error}
Контекст: {json.dumps(context[-3:], ensure_ascii=False)}
Доступные: {available}
Верни: {{"steps": [{{"tool": "ИМЯ_ИЗ_СПИСКА", "args": {{}}}}]}}"""
        resp = await _call_openrouter(p)
        data = _extract_json(resp)
        if not isinstance(data, dict): return []
        steps = data.get("steps", [])
        return [s for s in steps if isinstance(s, dict) and s.get("tool") in available] if isinstance(steps, list) else []
    except: return []
