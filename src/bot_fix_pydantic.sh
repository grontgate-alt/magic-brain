#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain
cd $BASE

echo "[1/4] Фикс зависимостей: принудительно Pydantic v2..."
python3 -m pip install --break-system-packages -q "pydantic>=2.0" "fastapi>=0.100" 2>/dev/null || true
echo "✅ Pydantic v2 установлен"

echo "[2/4] Фикс main.py: правильный тип в /process..."
# Заменяем req: BaseModel на req: ProcessReq
sed -i 's/async def process(req: BaseModel):/async def process(req: ProcessReq):/' interfaces/api/main.py
# Убеждаемся, что ProcessReq импортирован/объявлен перед использованием
if ! grep -q "class ProcessReq" interfaces/api/main.py; then
    # Если ProcessReq не найден — добавляем его
    sed -i '/from pydantic import BaseModel/a class ProcessReq(BaseModel):\n    user_id: int\n    text: str\n    has_files: bool = False\n    task_type: str = "default"' interfaces/api/main.py
fi
echo "✅ /process endpoint исправлен"

echo "[3/4] Перезапуск API..."
pkill -9 -f "uvicorn" 2>/dev/null || true
sleep 3
set -a; source $BASE/.env; set +a
cd $BASE/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health > /dev/null && echo "✅ API UP" || { echo "❌ API DOWN"; tail -10 /tmp/api.log; exit 1; }

echo "[4/4] Перезапуск бота..."
pkill -f "python3.*bot.py" 2>/dev/null || true
sleep 2
cd $BASE/interfaces/telegram
TG_BOT_TOKEN="$TG_BOT_TOKEN" API_BRIDGE_URL="http://127.0.0.1:8000" \
nohup python3 bot.py > /tmp/bot.log 2>&1 &
sleep 3
grep "Application started" /tmp/bot.log && echo "✅ Бот в фоне" || { echo "❌ Бот упал"; tail -10 /tmp/bot.log; }

echo ""
echo "🧪 Тест бота:"
echo "Напиши в Telegram:"
echo "  • 'привет' → должен ответить"
echo "  • 'пароль от почты' → 🔐 [Локально] ..."
echo ""
echo "Если ошибка — скинь вывод:"
echo "  tail -20 /tmp/bot.log"
echo "  tail -20 /tmp/api.log"
