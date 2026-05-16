#!/bin/bash
set -e
cd ~/magic-brain

echo "[1/3] Полная запись bot.py (кнопки + таймауты)..."
cat << 'PY' > interfaces/telegram/bot.py
import os, sys, re, json, logging, asyncio
from pathlib import Path
BASE = Path(__file__).parent.parent.parent
env = BASE / ".env"
if env.exists():
    for ln in env.read_text().splitlines():
        if "=" in ln and not ln.strip().startswith("#"):
            k,v = ln.split("=",1); os.environ[k.strip()]=v.strip()
if str(BASE) not in sys.path: sys.path.insert(0, str(BASE))
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, MessageHandler, filters, ContextTypes, CallbackQueryHandler
from telegram.error import BadRequest
import httpx

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
API_URL = os.getenv("API_BRIDGE_URL", "http://localhost:8000")
BOT_TOKEN = os.getenv("TG_BOT_TOKEN", "")

def esc(t): 
    if not t: return ""
    return re.sub(r'([_*\[\]()~`>#+\-=|{}.!\\])', r'\\\1', str(t))

async def reply(upd, txt, kb=None):
    try: await upd.message.reply_text(esc(txt), parse_mode="MarkdownV2", reply_markup=kb)
    except BadRequest: await upd.message.reply_text(txt, reply_markup=kb)

KB_ALWAYS = InlineKeyboardMarkup([
    [InlineKeyboardButton("🛠️ Агент", callback_data=json.dumps({"type":"agent_mode"}))],
    [InlineKeyboardButton("💬", callback_data=json.dumps({"type":"mode","mode":"chat"})),
     InlineKeyboardButton("🗄️", callback_data=json.dumps({"type":"mode","mode":"rag"})),
     InlineKeyboardButton("🌐", callback_data=json.dumps({"type":"mode","mode":"web"}))],
])

async def handle_callback(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query; await q.answer()
    d = json.loads(q.data); uid = q.from_user.id
    if d.get("type")=="agent_mode":
        context.user_data["force_agent"]=True; await q.edit_message_text("🛠️ Агент-режим: отправьте запрос...")
    elif d.get("type")=="clarify":
        await process_impl(q.message, f"/intent:{d['intent']} {d.get('query','')}", uid, context)
    elif d.get("type")=="mode":
        context.user_data["force_mode"]=d.get("mode","auto"); await q.edit_message_text(f"✅ Режим: {d.get('mode','auto')}")

async def process_impl(msg, text: str, uid: int, ctx: ContextTypes.DEFAULT_TYPE):
    fa = ctx.user_data.pop("force_agent", False)
    fm = ctx.user_data.get("force_mode","auto")
    io = None
    if text.startswith("/intent:"):
        p=text.split(" ",1); io=p[0].split(":")[1]; text=p[1] if len(p)>1 else text
    await reply(msg, "⏳ ...")
    try:
        async with httpx.AsyncClient(timeout=35) as c:
            r = await c.post(f"{API_URL}/process", json={"user_id":uid, "text":text, "has_files":False, "force_agent":fa, "force_mode":fm if fm!="auto" else None, "intent_override":io})
            d = r.json()
            await reply(msg, f"{d.get('reply','')}\n\n{d.get('tag','[❓]')}", KB_ALWAYS)
    except Exception as e:
        await reply(msg, f"⚠️ {str(e)[:100]}", KB_ALWAYS)

async def handle_msg(u, c): await process_impl(u.message, u.message.text or "", u.effective_user.id, c)
async def start_cmd(u, c): await reply(u, "🦌 Magic Brain\n\nПиши что угодно. Кнопки всегда ниже.", KB_ALWAYS)

def main():
    if not BOT_TOKEN or len(BOT_TOKEN)<20: print("❌ Нет токена"); return
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", start_cmd))
    app.add_handler(MessageHandler(filters.ALL, handle_msg))
    app.add_handler(CallbackQueryHandler(handle_callback))
    print("🤖 Бот запущен"); app.run_polling()

if __name__ == "__main__": main()
PY
echo "✅ bot.py готов"

echo "[2/3] Очистка и перезапуск API + Bot..."
pkill -f uvicorn 2>/dev/null || true; pkill -f "bot.py" 2>/dev/null || true
sleep 2

set -a; source ~/magic-brain/.env; set +a
cd ~/magic-brain/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
cd ~/magic-brain/interfaces/telegram
nohup python3 bot.py > /tmp/bot.log 2>&1 &
sleep 6

if curl -sf http://127.0.0.1:8000/health >/dev/null; then echo "✅ API UP"
else echo "❌ API DOWN → tail -20 /tmp/api.log"
fi
grep -q "Бот запущен" /tmp/bot.log && echo "✅ Bot UP" || echo "⚠️ Bot error → tail /tmp/bot.log"

echo "[3/3] Тест..."
echo "Напиши боту: 'Покажи файлы в /home/der'"
echo "Ожидаемо: список файлов + тег [🛠️mcp] + кнопки под сообщением"
echo "ЖДУ: результат или tail -20 /tmp/api.log"
