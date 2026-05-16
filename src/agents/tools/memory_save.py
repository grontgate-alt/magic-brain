"""Скилл: сохранение данных в память пользователя"""
import uuid

def __skill__():
    return {
        "name": "memory_save",
        "desc": "Сохранение текста/фактов в приватное хранилище пользователя",
        "params": {"content": "текст для сохранения", "user_id": "int"},
        "privacy": "LOCAL"
    }

async def memory_save(query: str, context: dict, user_id: int, **kwargs) -> str:
    """Сохраняет контент в RAG"""
    store = context.get("store")
    embedder = context.get("embedder")
    
    if not store or not embedder:
        return "⚠️ Хранилище недоступно"
    
    # Извлекаем контент из запроса (после "сохрани:")
    content = query
    if ":" in query:
        content = query.split(":", 1)[1].strip()
    
    try:
        vec = embedder.embed([content])[0]
        payload = {"text": content, "user_id": user_id, "type": "user_memory", "privacy": "HIGH"}
        store.upsert([vec], [payload], [f"mem_{uuid.uuid4().hex[:12]}"])
        return f"✅ Сохранено в твою память: {content[:80]}{'...' if len(content)>80 else ''}"
    except Exception as e:
        return f"⚠️ Ошибка сохранения: {str(e)[:100]}"
