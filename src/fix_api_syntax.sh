#!/bin/bash
set -e
cd ~/magic-brain

echo "[1/4] Чиним main.py: добавляем импорт Dict и эндпоинты режимов..."
# Проверяем, есть ли уже импорт Dict
if ! grep -q "from typing import Dict" interfaces/api/main.py; then
    sed -i '1a from typing import Dict' interfaces/api/main.py
fi

# Если эндпоинты уже добавлены, убираем дубли
sed -i '/user_modes: Dict/,/^@/d' interfaces/api/main.py 2>/dev/null || true

# Добавляем чистые эндпоинты в конец
cat << 'PY' >> interfaces/api/main.py

# === User Mode Persistence ===
user_modes: Dict[int, str] = {}

@app.post("/user/{user_id}/mode")
async def set_user_mode(user_id: int, payload: dict):
    mode = payload.get("mode", "auto")
    if mode not in ("auto","chat","tools","rag","web"):
        return {"error": "invalid mode"}
    user_modes[user_id] = mode
    return {"status": "ok", "mode": mode}

@app.get("/user/{user_id}/mode")
async def get_user_mode(user_id: int):
    return {"mode": user_modes.get(user_id, "auto")}
PY
echo "✅ main.py fixed"

echo "[2/4] Чиним orchestrator.py: правильная сигнатура process()..."
# Находим строку с process и заменяем её на корректную
python3 << 'PY'
import re
path = "agents/main/orchestrator.py"
with open(path, "r") as f: content = f.read()

# Исправляем сигнатуру: добавляем force_mode корректно
old = re.search(r'async def process\(self.*?\) -> dict:', content, re.DOTALL)
if old:
    new_sig = '''async def process(self, user_query: str, user_id: int, task_type: str = "default", 
                      force_agent: bool = False, force_mode: str = None, intent_override: str = None) -> dict:'''
    content = content[:old.start()] + new_sig + content[old.end():]
    with open(path, "w") as f: f.write(content)
    print("✅ signature fixed")
else:
    print("⚠️ signature not found, skipping")
PY

# Проверяем синтаксис
python3 -m py_compile interfaces/api/main.py && echo "✅ main.py OK" || echo "❌ main.py syntax error"
python3 -m py_compile agents/main/orchestrator.py && echo "✅ orchestrator.py OK" || echo "❌ orchestrator.py syntax error"

echo "[3/4] Перезапуск..."
pkill -9 -f uvicorn 2>/dev/null || true
pkill -9 -f "bot.py" 2>/dev/null || true
sleep 2

set -a; source ~/magic-brain/.env; set +a
cd ~/magic-brain/interfaces/api
python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 5

if curl -sf --max-time 5 http://127.0.0.1:8000/health >/dev/null; then
    echo "✅ API UP"
else
    echo "❌ API всё ещё DOWN. Лог ошибки:"
    tail -15 /tmp/api.log
    exit 1
fi

cd ~/magic-brain/interfaces/telegram
python3 bot.py > /tmp/bot.log 2>&1 &
sleep 3
grep -q "started\|Started" /tmp/bot.log && echo "✅ Bot UP" || echo "⚠️ Bot check: tail /tmp/bot.log"

echo "[4/4] Готово."
echo "🧪 Тест: напиши боту 'привет' или нажми кнопку"
echo "ЖДУ: подтверждение или tail -10 /tmp/api.log если ошибка."
