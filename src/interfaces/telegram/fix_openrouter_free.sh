#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain
cd $BASE

echo "[1/2] Фикс openrouter_client: используем openrouter/free..."
cat << 'PY' > privacy/local_llm/openrouter_client.py
import os, httpx, json

class OpenRouterClient:
    def __init__(self, api_key: str = None, router=None):
        self.api_key = api_key or os.getenv("OPENROUTER_API_KEY", "")
        self.router = router
        self.base_url = "https://openrouter.ai/api/v1"
        # ✅ Правильный роутер бесплатных моделей
        self.model = "openrouter/free"

    async def chat(self, prompt: str, context: list = None) -> str:
        if not self.api_key or len(self.api_key) < 20:
            return "⚠️ OpenRouter ключ не задан. Проверь .env"
        
        ctx = "\n".join(context) if context else ""
        messages = [{"role": "system", "content": "Отвечай кратко и по делу."}]
        if ctx: messages.append({"role": "system", "content": f"Контекст: {ctx}"})
        messages.append({"role": "user", "content": prompt})
        
        try:
            async with httpx.AsyncClient(timeout=60) as c:
                r = await c.post(
                    f"{self.base_url}/chat/completions",
                    headers={
                        "Authorization": f"Bearer {self.api_key}",
                        "HTTP-Referer": "http://localhost",
                        "X-Title": "MagicBrain",
                        "Content-Type": "application/json"
                    },
                    json={
                        "model": self.model,  # ✅ openrouter/free
                        "messages": messages,
                        "max_tokens": 1024,
                        "temperature": 0.7
                    }
                )
                if r.status_code == 200:
                    d = r.json()
                    content = d.get("choices",[{}])[0].get("message",{}).get("content","").strip()
                    # Сохраняем фактическую модель из ответа
                    actual_model = d.get("model", "openrouter/free")
                    return content
                elif r.status_code == 401:
                    return "⚠️ OpenRouter: неверный ключ"
                elif r.status_code == 429:
                    return "⚠️ OpenRouter: лимит, подожди минуту"
                else:
                    return f"⚠️ OpenRouter {r.status_code}: {r.text[:150]}"
        except httpx.TimeoutException:
            return "⚠️ OpenRouter: таймаут"
        except Exception as e:
            return f"⚠️ OpenRouter: {type(e).__name__}: {str(e)[:100]}"
PY
echo "✅ openrouter_client: openrouter/free"

echo "[2/2] Перезапуск API..."
pkill -f uvicorn 2>/dev/null || true
sleep 3
set -a; source $BASE/.env; set +a
cd $BASE/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health && echo "✅ API UP" || { echo "❌ API DOWN"; tail -10 /tmp/api.log; }

echo ""
echo "🧪 Тест (напиши боту):"
echo "  • 'привет' → ответ с [☁️openrouter/free +RAG:N]"
echo "  • 'Мой пароль = Test123' → сохранится в RAG"
echo "  • 'Напомни пароль' → найдёт и покажет"
echo ""
echo "Если ошибка — скинь: tail -15 /tmp/api.log"
echo "ЖДУ: результат."
