#!/usr/bin/env python3
import os, sys, httpx, json
from pathlib import Path

BASE = Path(__file__).parent
if str(BASE) not in sys.path: sys.path.insert(0, str(BASE))

# Загружаем .env
env = BASE / ".env"
if env.exists():
    for ln in env.read_text().splitlines():
        if "=" in ln and not ln.startswith("#"):
            k,v = ln.split("=",1)
            os.environ.setdefault(k.strip(), v.strip())

API_KEY = os.getenv("OPENROUTER_API_KEY", "")
print(f"🔑 OPENROUTER_API_KEY: {'✅ задан' if API_KEY and len(API_KEY)>10 else '❌ пустой/короткий'}")

if not API_KEY:
    print("💡 Вставь ключ от https://openrouter.ai/keys")
    sys.exit(1)

async def test():
    url = "https://openrouter.ai/api/v1/chat/completions"
    headers = {
        "Authorization": f"Bearer {API_KEY}",
        "HTTP-Referer": "http://localhost",
        "X-Title": "MagicBrain-Test",
        "Content-Type": "application/json"
    }
    payload = {
        "model": "qwen/qwen-2.5-7b-instruct:free",
        "messages": [{"role": "user", "content": "привет, ответь одним словом"}]
    }
    
    print(f"🌐 POST {url}")
    print(f"📦 Payload: {json.dumps(payload, ensure_ascii=False)[:100]}...")
    
    try:
        async with httpx.AsyncClient(timeout=30) as c:
            r = await c.post(url, headers=headers, json=payload)
            print(f"📡 HTTP {r.status_code}")
            
            if r.status_code == 200:
                d = r.json()
                content = d.get("choices",[{}])[0].get("message",{}).get("content","")
                model = d.get("model","?")
                print(f"✅ OK | Модель: {model} | Ответ: {content[:80]}")
                return True
            else:
                print(f"❌ Error: {r.text[:300]}")
                return False
    except Exception as e:
        print(f"❌ Exception: {type(e).__name__}: {e}")
        return False

import asyncio
asyncio.run(test())
