import json
import logging
import os
import sys
import traceback
from pathlib import Path

BASE = Path(__file__).parent.parent.parent
sys.path.insert(0, str(BASE))

# Загружаем .env
env = BASE / ".env"
if env.exists():
    for ln in env.read_text().splitlines():
        if "=" in ln and not ln.strip().startswith("#"):
            k, v = ln.split("=", 1)
            os.environ[k.strip()] = v.strip()

import httpx
from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.ext import Application, CallbackQueryHandler, ContextTypes, MessageHandler, filters

# Логирование ВСЕГО
logging.basicConfig(level=logging.DEBUG, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger(__name__)

API_URL = os.getenv("API_BRIDGE_URL", "http://localhost:8000")
BOT_TOKEN = os.getenv("TG_BOT_TOKEN", "")

if not BOT_TOKEN:
    logger.error("❌ TG_BOT_TOKEN not set!")
    sys.exit(1)

logger.info(f"🔑 Token: {BOT_TOKEN[:20]}...")
logger.info(f"🌐 API: {API_URL}")

KB = InlineKeyboardMarkup(
    [
        [
            InlineKeyboardButton("🛠️", callback_data=json.dumps({"t": "agent"})),
            InlineKeyboardButton("💬", callback_data=json.dumps({"t": "chat"})),
            InlineKeyboardButton("🗄️", callback_data=json.dumps({"t": "rag"})),
        ]
    ]
)


async def reply(msg, text):
    try:
        logger.info(f"📤 Sending: {text[:100]}...")
        await msg.reply_text(text, reply_markup=KB)
        logger.info("✅ Sent OK")
    except Exception as e:
        logger.error(f"❌ Send error: {e}\n{traceback.format_exc()}")
        await msg.reply_text(f"Error: {str(e)[:100]}")


async def handle_cb(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    logger.info(f"🔘 Callback: {q.data} from user {q.from_user.id}")
    await q.answer()
    d = json.loads(q.data)
    if d.get("t") == "agent":
        ctx.user_data["force_agent"] = True
        await q.edit_message_text("🛠️ Агент: пиши запрос...")
    elif d.get("t") in ("chat", "rag"):
        ctx.user_data["mode"] = d.get("t")
        await q.edit_message_text(f"✅ Режим: {d.get('t')}")


async def handle_msg(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    try:
        uid = update.effective_user.id
        text = update.message.text or ""
        logger.info(f"📨 Message from {uid}: {text[:100]}")

        await reply(update.message, "⏳ Обработка...")

        # Пробуем вызвать API
        async with httpx.AsyncClient(timeout=35) as c:
            logger.info(f"🌐 POST {API_URL}/process")
            r = await c.post(
                f"{API_URL}/process",
                json={
                    "user_id": uid,
                    "text": text,
                    "has_files": False,
                    "force_agent": ctx.user_data.pop("force_agent", False),
                    "force_mode": ctx.user_data.get("mode"),
                },
            )
            logger.info(f"📡 HTTP {r.status_code}")
            d = r.json()
            await reply(update.message, f"{d.get('reply', '')}\n\n{d.get('tag', '')}")
    except Exception as e:
        logger.error(f"❌ Handler error: {e}\n{traceback.format_exc()}")
        await reply(update.message, f"⚠️ Ошибка: {str(e)[:150]}")


def main():
    logger.info("🤖 Starting bot...")
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(MessageHandler(filters.TEXT, handle_msg))
    app.add_handler(CallbackQueryHandler(handle_cb))
    logger.info("✅ Handlers registered, starting polling...")
    app.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    main()
