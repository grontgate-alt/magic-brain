"""Скилл: извлечение данных из памяти пользователя"""

def __skill__():
    return {
        "name": "memory_recall",
        "desc": "Поиск и возврат сохранённых данных пользователя из RAG",
        "params": {"query": "строка запроса", "user_id": "int"},
        "privacy": "LOCAL"
    }

async def memory_recall(query: str, context: dict, user_id: int, **kwargs) -> str:
    """Прямой поиск в хранилище, без LLM"""
    # Используем store из контекста если есть
    store = context.get("store")
    embedder = context.get("embedder")
    
    if not store or not embedder:
        return "⚠️ Хранилище недоступно"
    
    try:
        vec = embedder.embed([query])[0]
        results = store.search(vec, limit=5)
        found = []
        for r in results:
            p = r.get("payload") or r.get("meta") or {}
            if p.get("user_id") in (None, user_id):
                txt = p.get("text") or ""
                if txt and query.lower() in txt.lower():
                    found.append(txt.strip())
        
        if found:
            return "Найдено:\n" + "\n".join(f"• {t}" for t in found[:3])
        return "⚠️ Ничего не найдено по этому запросу в твоей памяти"
    except Exception as e:
        return f"⚠️ Ошибка поиска: {str(e)[:100]}"
