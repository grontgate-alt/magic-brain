#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain

echo "[1/4] Чистим .env от дублей и кавычек..."
# Удаляем ВСЕ строки TG_BOT_TOKEN
sed -i '/^TG_BOT_TOKEN=/d' $BASE/.env
# Добавляем ОДНУ чистую строку (без кавычек!)
echo 'TG_BOT_TOKEN=8781692977:AAEkAIJdRJuyC22eFRoNdewKZxhDD4udLKg' >> $BASE/.env
echo "✅ .env очищен"
grep TG_BOT $BASE/.env

echo "[2/4] Фикс bot.py: используем = вместо setdefault..."
cat << 'PY' > $BASE/interfaces/telegram/bot.py
import os, sys, re, json, logging
from pathlib import Path

BASE = Path(__file__).parent.parent.parent

# === ЧИТАЕМ .env ПЕРЕД ВСЕМ (с перезаписью!) ===
env_path = BASE / ".env"
if env_path.exists():
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            os.environ[k.strip()] = v.strip()  # ✅ перезаписываем, не setdefault

if str(BASE) not in sys.path: sys.path.insert(0, str(BASE))
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, MessageHandler, filters, ContextTypes, CallbackQueryHandler
from telegram.error import BadRequest
import httpx

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
API_URL = os.getenv("API_BRIDGE_URL", "http://localhost:8000")
BOT_TOKEN = os.getenv("TG_BOT_TOKEN", "")

print(f"🔍 DEBUG: BOT_TOKEN len={len(BOT_TOKEN)}, start='{BOT_TOKEN[:10] if BOT_TOKEN else 'пусто'}'")

def esc_md(text: str) -> str:
    if not text: return text
    return re.sub(r'([_*\[\]()~`>#+\-=|{}.!\\])', r'\\\1', text)

async def safe_reply(update: Update, text: str, keyboard=None):
    try:
        await update.message.reply_text(esc_md(text), parse_mode="MarkdownV2", reply_markup=keyboard)
    except BadRequest:
        await update.message.reply_text(text, reply_markup=keyboard)

async def handle_confirm(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    data = json.loads(query.data)
    if data.get("action") == "show_secret":
        await query.edit_message_text("🔐 Значение: \`[из базы]\`", parse_mode="Markdown")
    else:
        await query.edit_message_text("✅ Отменено")

async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uid = update.effective_user.id
    text = update.message.text or ""
    keyboard = None
    await safe_reply(update, "⏳ Думаю...", keyboard)
    try:
        async with httpx.AsyncClient(timeout=120.0) as c:
            r = await c.post(f"{API_URL}/process", json={"user_id":uid, "text":text, "has_files":False, "task_type":"default"})
            res = r.json()
            if "error" in res: 
                reply = f"⚠️ {res['error'][:150]}"
            else:
                mode = res.get("privacy_mode","")
                model = res.get("model_used","")
                rag_hits = res.get("context_used",0)
                reply_text = res.get("reply","")
                sensitive = res.get("sensitive_found", False)
                tag = f"🔐 {model}" if mode=="LOCAL" else f"☁️ {model}"
                if rag_hits > 0: tag += f" +RAG:{rag_hits}"
                if sensitive and ("покажи" in text.lower() or "пароль" in text.lower()):
                    keyboard = InlineKeyboardMarkup([[
                        InlineKeyboardButton("✅ Показать", callback_data=json.dumps({"action":"show_secret"})),
                        InlineKeyboardButton("❌ Отмена", callback_data=json.dumps({"action":"cancel"}))
                    ]])
                reply = f"{reply_text}\n\n_({tag})_"
            await safe_reply(update, reply, keyboard)
    except Exception as e:
        await safe_reply(update, f"⚠️ Ошибка: {str(e)[:100]}", keyboard)

async def start_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await safe_reply(update, "🦌 Magic Brain.\n🔐 Всё локально. Пиши что угодно.", None)

def main():
    if not BOT_TOKEN or len(BOT_TOKEN) < 20:
        print(f"❌ Нет валидного токена. Длина: {len(BOT_TOKEN)}")
        return
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", start_cmd))
    app.add_handler(MessageHandler(filters.ALL, handle_message))
    app.add_handler(CallbackQueryHandler(handle_confirm))
    print(f"🤖 Бот запущен. Токен: {BOT_TOKEN[:10]}...")
    app.run_polling()

if __name__ == "__main__": main()
PY
echo "✅ bot.py: = вместо setdefault"

echo "[3/4] Убиваем старые процессы..."
pkill -9 -f "python3.*bot.py" 2>/dev/null || true
sleep 2

echo "[4/4] Запуск..."
cd $BASE/interfaces/telegram
python3 bot.py > /tmp/bot.log 2>&1 &
sleep 4

echo "=== Результат ==="
if grep -q "Бот запущен" /tmp/bot.log; then
    echo "✅ Бот работает!"
    grep "DEBUG\|Бот запущен" /tmp/bot.log
    echo ""
    echo "📍 Тесты в Telegram:"
    echo "  1. 'привет'"
    echo "  2. 'сохрани: мой пароль от почты = Test123'"
    echo "  3. 'покажи мой пароль от почты'"
else
    echo "❌ Бот не стартовал"
    cat /tmp/bot.log
fi
