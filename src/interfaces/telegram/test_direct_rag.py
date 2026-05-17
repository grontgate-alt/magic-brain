#!/usr/bin/env python3
import os
import sys
from pathlib import Path

BASE = Path(__file__).parent
sys.path.insert(0, str(BASE))

# Инициализация
os.environ.setdefault("QDRANT_HOST", "localhost")
os.environ.setdefault("QDRANT_PORT", "6333")

import uuid

from rag.embed.local_embedder import LocalEmbedder
from rag.store.qdrant_client import RAGStore

embedder = LocalEmbedder()
store = RAGStore()

print("=== ТЕСТ: Прямой RAG (без LLM) ===\n")

# 1. Сохраняем
user_id = 999
secret = "мой пароль от почты = SuperSecret123"
meta = {"user_id": user_id, "type": "secret", "privacy": "HIGH"}
vec = embedder.embed([secret])[0]
doc_id = f"test_{uuid.uuid4().hex[:8]}"
store.upsert([vec], [meta], [doc_id])
print(f"✅ Сохранено: '{secret}'")
print(f"   ID: {doc_id}\n")

# 2. Ищем
query = "покажи пароль от почты"
q_vec = embedder.embed([query])[0]
results = store.search(q_vec, limit=3)
print(f"🔍 Поиск по запросу: '{query}'")
print(f"   Найдено: {len(results)} документов\n")

# 3. Показываем
for i, r in enumerate(results, 1):
    text = r.get("text", "")
    m = r.get("meta", {})
    print(f"{i}. Текст: {text}")
    print(f"   Мета: user_id={m.get('user_id')}, type={m.get('type')}\n")

# 4. Проверка
found = any(secret in r.get("text", "") for r in results)
print(f"{'✅ PASS' if found else '❌ FAIL'}: Секрет найден в результатах")

# Очистка теста
try:
    store.qdrant.delete_points(store.collection_name, points=[doc_id])
    print("✅ Тестовая запись удалена")
except:
    pass
