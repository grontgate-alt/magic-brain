#!/usr/bin/env python3
import httpx, json

API_URL = "http://127.0.0.1:8000"
USER_ID = 999

query = "мой знакомы спросил меня о рецепте блинов и сколько надо муки на 100 блинов, он попросил отправить ответ на почту 23424@eskd.com и смской на тел 234234234, у почты его пароль 654укапе54у"

print("🔍 Тестируем сложный запрос (рецепт + приватные данные):\n")
print(f"Запрос: {query[:100]}...\n")

try:
    with httpx.Client(timeout=90) as c:
        r = c.post(f"{API_URL}/process", json={
            "user_id": USER_ID,
            "text": query,
            "has_files": False,
            "task_type": "default"
        })
        d = r.json()
        print(f"✅ HTTP: {r.status_code}")
        print(f"🔐 privacy_mode: {d.get('privacy_mode','?')}")
        print(f"🤖 model_used: {d.get('model_used','?')}")
        print(f"📚 context_used: {d.get('context_used','?')}")
        print(f"\n💬 Ответ ({len(d.get('reply',''))} симв.):")
        print("-" * 60)
        print(d.get('reply',''))
        print("-" * 60)
        
        # Проверка: вернулись ли оригинальные данные?
        reply = d.get('reply','')
        checks = [
            ("23424@eskd.com", "email"),
            ("234234234", "phone"), 
            ("654укапе54у", "password")
        ]
        print("\n🔍 Проверка приватности:")
        for val, name in checks:
            status = "✅" if val in reply else "❌"
            print(f"   {status} {name} в ответе: {val in reply}")
            
except Exception as e:
    print(f"❌ Ошибка: {e}")
    import traceback; traceback.print_exc()
