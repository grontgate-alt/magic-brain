#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain

echo "=== 1. Проверка процесса бота ==="
ps aux | grep "[b]ot.py" || echo "❌ Бот не запущен"

echo ""
echo "=== 2. Проверка токена в среде ==="
if [ -n "$TG_BOT_TOKEN" ]; then
    echo "✅ TG_BOT_TOKEN установлен: ${TG_BOT_TOKEN:0:15}..."
else
    echo "❌ TG_BOT_TOKEN не установлен в текущей сессии"
    echo "   Запусти: export TG_BOT_TOKEN=123456:AAA..."
fi

echo ""
echo "=== 3. Проверка связи с API ==="
curl -sf http://127.0.0.1:8000/health && echo "✅ API доступен" || echo "❌ API недоступен"

echo ""
echo "=== 4. Логи бота (если есть) ==="
cat /tmp/bot.log 2>/dev/null | tail -20 || echo "Файл лога не найден"

echo ""
echo "=== 5. Быстрый тест бота вручную ==="
echo "Запускаю бот в этом терминале (Ctrl+C для остановки)..."
cd $BASE/interfaces/telegram
TG_BOT_TOKEN="${TG_BOT_TOKEN:-YOUR_TOKEN_HERE}" API_BRIDGE_URL="http://127.0.0.1:8000" \
python3 -u bot.py 2>&1 | head -50

echo ""
echo "Если бот стартовал — напиши 'привет' ему в Telegram."
echo "Если ошибка — скинь вывод."
