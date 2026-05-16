#!/usr/bin/env python3
import httpx, json, os

API_URL = "http://127.0.0.1:8000"
USER_ID = 999

tests = [
    ("привет", "обычный запрос"),
    ("Мой пароль = Test123", "приватный запрос"),
    ("Напомни пароль", "запрос к RAG"),
]

print("🔍 Тестируем /process напрямую:\n")
for query, desc in tests:
    print(f"📝 {desc}: '{query}'")
    try:
        with httpx.Client(timeout=60) as c:
            r = c.post(f"{API_URL}/process", json={
                "user_id": USER_ID,
                "text": query,
                "has_files": False,
                "task_type": "default"
            })
            d = r.json()
            print(f"   HTTP: {r.status_code}")
            print(f"   reply: {d.get('reply','')[:100]}...")
            print(f"   privacy_mode: {d.get('privacy_mode','?')}")
            print(f"   model_used: {d.get('model_used','?')}")
            print(f"   context_used: {d.get('context_used','?')}")
            print()
    except Exception as e:
        print(f"   ❌ Ошибка: {e}\n")
