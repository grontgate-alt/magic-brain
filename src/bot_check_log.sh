#!/bin/bash
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain

echo "=== 1. Лог бота (последние 20 строк) ==="
cat /tmp/bot.log 2>/dev/null | tail -20 || echo "Файл не найден"

echo ""
echo "=== 2. Проверка токена ==="
echo "TG_BOT_TOKEN=${TG_BOT_TOKEN:0:15}..."

echo ""
echo "=== 3. Ручной запуск для отладки ==="
echo "Запускаю бота в этом терминале (Ctrl+C для остановки)..."
cd $BASE/interfaces/telegram
TG_BOT_TOKEN="$TG_BOT_TOKEN" API_BRIDGE_URL="http://127.0.0.1:8000" python3 bot.py 2>&1 | head -30

echo ""
echo "Если запустился — напиши боту в Telegram:"
echo "  1. 'привет'"
echo "  2. 'сохрани: мой пароль от почты = Test123'"
echo "  3. 'покажи мой пароль от почты'"
echo ""
echo "ЖДУ: вывод ручного запуска или подтверждение работы."
