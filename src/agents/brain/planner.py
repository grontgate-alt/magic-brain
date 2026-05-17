import os, json, re, logging, inspect
from privacy.local_llm.openrouter_client import OpenRouterClient

async def _call_openrouter(prompt: str) -> str:
    client = OpenRouterClient(api_key=os.getenv("OPENROUTER_API_KEY"))
    
    # Проверяем поддерживаемые параметры динамически
    sig = inspect.signature(client.chat)
    allowed = set(sig.parameters.keys()) - {'self'}
    
    kwargs = {"prompt": prompt, "context": []}
    extra_params = {
        "response_format": {"type": "json_object"},
        "temperature": 0.1
    }
    
    # Добавляем только те, что есть в сигнатуре
    for k, v in extra_params.items():
        if k in allowed: kwargs[k] = v
        else: logging.debug(f"⏭️ Параметр {k} не поддерживается клиентом")

    try:
        resp = await client.chat(**kwargs)
        logging.info(f"📥 Planner response: {len(resp)} chars")
        return resp
    except Exception as e:
        logging.error(f"❌ OpenRouter call failed: {e}")
        return "{}"

async def plan(query: str, registry) -> list:
    logging.info("🧠 Planner starting...")
    tools = [{"name":n, "desc":s["desc"], "params":list(s.get("params",{}).keys())} 
             for n,s in registry.skills.items()][:30]
    
    prompt = f"""Ты — планировщик ИИ-агента. Разбей запрос на шаги.
ДОСТУПНЫЕ ИНСТРУМЕНТЫ: {json.dumps(tools, ensure_ascii=False)}
ЗАПРОС: {query}
ВЕРНИ СТРОГО JSON: {{"steps": [{{"tool":"имя_инструмента", "args":{{"параметр":"значение"}}}}]}}
Правила: 1) Только существующие инструменты. 2) Максимум 4 шага. 3) Только JSON."""
    
    try:
        resp = await _call_openrouter(prompt)
        # Парсинг JSON с поддержкой markdown-блоков
        m = re.search(r'```(?:json)?\s*(\{.*?\})\s*```', resp, re.DOTALL)
        if not m: m = re.search(r'(\{.*\})', resp, re.DOTALL)
        
        if m:
            data = json.loads(m.group(1) if m.lastindex else m.group(0))
            # Поддержка обоих форматов: {"steps": [...]} или {"tool": "..."}
            if "steps" in data:
                steps = data["steps"]
            elif "tool" in data:
                steps = [data]  # Один инструмент → оборачиваем в список
            else:
                steps = []
            logging.info(f"📋 Plan parsed: {[s.get('tool') for s in steps]}")
            return steps
            
        logging.warning(f"⚠️ JSON not found in response: {resp[:200]}")
        return []
    except Exception as e:
        logging.error(f"💥 Planner crash: {e}")
        return []

async def replan(error: str, context: list, registry) -> list:
    tools = [{"name":n} for n in registry.skills.keys()][:30]
    prompt = f"""Шаги упали. Скорректируй план.
ОШИБКА: {error}
КОНТЕКСТ: {json.dumps(context[-3:], ensure_ascii=False)}
ВЕРНИ: {{"steps": [{{"tool":"имя", "args":{{}}}}]}}"""
    try:
        resp = await _call_openrouter(prompt)
        m = re.search(r'\{.*\}', resp, re.DOTALL)
        return json.loads(m.group()).get("steps", []) if m else []
    except Exception as e:
        logging.error(f"💥 replan: {e}")
        return []
