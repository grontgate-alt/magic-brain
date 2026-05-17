#!/usr/bin/env python3
import os
import sys
import uuid
from pathlib import Path

BASE = Path(__file__).parent.parent.parent
if str(BASE) not in sys.path:
    sys.path.insert(0, str(BASE))
os.chdir(BASE)

os.environ.setdefault("QDRANT_HOST", "localhost")
os.environ.setdefault("QDRANT_PORT", "6333")

from rag.embed.local_embedder import LocalEmbedder
from rag.store.qdrant_client import RAGStore

embedder = LocalEmbedder()
store = RAGStore()

print("=== ТЕСТ: Прямой RAG (без LLM) ===\n")

# 1. Сохраняем
user_id = 999
secret = "мой пароль от почты = SuperSecret123"
meta = {"user_id": user_id, "type": "secret", "privacy": "HIGH", "text": secret}
vec = embedder.embed([secret])[0]

# ✅ FIX: используем валидный UUID (без префиксов!)
doc_id = str(uuid.uuid4())
print(f"🆔 Генерируем UUID: {doc_id}")

store.upsert([vec], [meta], [doc_id])
print(f"✅ Сохранено: '{secret}'\n")

# 2. Ищем
query = "покажи пароль от почты"
q_vec = embedder.embed([query])[0]
results = store.search(q_vec, limit=3)
print(f"🔍 Поиск: '{query}' → найдено {len(results)}\n")

# 3. Показываем
for i, r in enumerate(results, 1):
    text = r.get("text", "") or r.get("meta", {}).get("text", "")
    m = r.get("meta", {})
    print(f"{i}. {text}")
    print(f"   meta: user_id={m.get('user_id')}, type={m.get('type')}\n")

# 4. Проверка
found = any(secret in (r.get("text", "") or r.get("meta", {}).get("text", "")) for r in results)
print(f"{'✅ PASS' if found else '❌ FAIL'}: Секрет найден")

# Очистка
try:
    store.qdrant.delete_points(store.collection_name, points=[doc_id])
    print("✅ Тест удалён")
except Exception as e:
    print(f"⚠️ Не удалил: {e}")
