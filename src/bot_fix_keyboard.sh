#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain

echo "[1/2] Фикс bot.py: инициализация keyboard в начале..."
cat << 'PY' > $BASE/interfaces/telegram/bot.py
import os, sys, logging, re, json
from pathlib import Path
BASE = Path(__file__).parent.parent.parent
if str(BASE) not in sys.path: sys.path.insert(0, str(BASE))
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, MessageHandler, filters, ContextTypes, CallbackQueryHandler
from telegram.error import BadRequest
import httpx

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
API_URL = os.getenv("API_BRIDGE_URL", "http://localhost:8000")
BOT_TOKEN = os.getenv("TG_BOT_TOKEN", "")

def esc(text: str) -> str:
    return re.sub(r'([_*[\]~`>#+\-=|{}.!])', r'\\\1', str(text))

async def safe_reply(update: Update, text: str, keyboard=None):
    try:
        await update.message.reply_text(esc(text), parse_mode="MarkdownV2", reply_markup=keyboard)
    except BadRequest:
        await update.message.reply_text(text, reply_markup=keyboard)

async def handle_confirm(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    data = json.loads(query.data)
    if data.get("action") == "show_secret":
        await query.edit_message_text(f"🔐 Сохранённое значение:\n`{data.get('value','[скрыто]')}`", parse_mode="Markdown")
    else:
        await query.edit_message_text("✅ Отменено")

async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uid = update.effective_user.id
    text = update.message.text or ""
    keyboard = None  # ✅ Инициализация в начале!
    
    await safe_reply(update, "⏳ Думаю\\.\\.\\.", keyboard)
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
                
                if sensitive and ("пароль" in text.lower() or "password" in text.lower()):
                    keyboard = InlineKeyboardMarkup([[
                        InlineKeyboardButton("✅ Показать", callback_data=json.dumps({"action":"show_secret","value":"[значение из базы]"})),
                        InlineKeyboardButton("❌ Отмена", callback_data=json.dumps({"action":"cancel"}))
                    ]])
                    reply_text = reply_text.split("⚠️ В базе найдено")[0].strip()
                
                reply = f"{reply_text}\n\n\\_\\({tag}\\)"
            await safe_reply(update, reply, keyboard)
    except Exception as e:
        await safe_reply(update, f"⚠️ Ошибка: {str(e)[:100]}", keyboard)

async def start_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await safe_reply(update, "🦌 Magic Brain\\.\n🔐 Приватность: локальная\\. Всё общение сохраняется в твоём RAG\\.\nПиши что угодно\\.", None)

def main():
    if not BOT_TOKEN: print("❌ Нет токена"); return
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", start_cmd))
    app.add_handler(MessageHandler(filters.ALL, handle_message))
    app.add_handler(CallbackQueryHandler(handle_confirm))
    print("🤖 Бот запущен"); app.run_polling()

if __name__ == "__main__": main()
PY
echo "✅ bot.py исправлен (keyboard инициализирован)"

echo "[2/2] Перезапуск бота..."
pkill -f "python3.*bot.py" 2>/dev/null || true
sleep 2
cd $BASE/interfaces/telegram
TG_BOT_TOKEN="$TG_BOT_TOKEN" API_BRIDGE_URL="http://127.0.0.1:8000" \
nohup python3 bot.py > /tmp/bot.log 2>&1 &
sleep 3
grep "Бот запущен" /tmp/bot.log && echo "✅ Бот перезапущен" || { echo "❌ Ошибка"; tail -10 /tmp/bot.log; }

echo ""
echo "Тест: напиши боту 'привет' и 'мой пароль = test123'"
echo "Если работает — пиши 21b для агентов."
