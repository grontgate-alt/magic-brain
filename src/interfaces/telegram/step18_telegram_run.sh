#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain

echo "🤖 1. Запуск Telegram-бота..."
read -sp "Вставь токен от @BotFather: " TG_TOKEN; echo ""
[ -z "$TG_TOKEN" ] && { echo "❌ Пусто."; exit 1; }

echo "[2/3] Фоновый запуск..."
pkill -f "python3.*bot.py" 2>/dev/null || true
cd $BASE/interfaces/telegram
TG_BOT_TOKEN="$TG_TOKEN" API_BRIDGE_URL="http://127.0.0.1:8000" \
nohup python3 bot.py > /tmp/bot.log 2>&1 &
sleep 3
grep "Бот запущен" /tmp/bot.log && echo "✅ Бот в фоне" || echo "⚠️ Проверь /tmp/bot.log"

echo "[3/3] Чек-лист:"
echo "• Открой бота в TG → /start"
echo "• Напиши 'рецепт борща' → ответ от облака (10-20 сек)"
echo "• Напиши 'мой пароль от почты' → ответ от локальной модели 🔐"
echo "• Кидай PDF/TXT → сохранится в RAG (ингест в процессе доработки)"
echo ""
echo "ЖДУ: ОК или 'СКЛ' для добавления первых 10 скилов."
