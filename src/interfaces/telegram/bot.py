import json
import logging
import os
import sys
from pathlib import Path

import httpx

BASE = Path(__file__).parent.parent.parent
sys.path.insert(0, str(BASE))
for ln in (BASE / ".env").read_text().splitlines():
    if "=" in ln and not ln.strip().startswith("#"):
        k, v = ln.split("=", 1)
        os.environ[k.strip()] = v.strip()

from telegram import Update
from telegram.ext import Application, CallbackQueryHandler, ContextTypes, MessageHandler, filters

from interfaces.telegram.ui import get_keyboard, safe_reply

API_URL = os.getenv("API_BRIDGE_URL", "http://localhost:8000")
BOT_TOKEN = os.getenv("TG_BOT_TOKEN", "")
logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(message)s")


async def handle_cb(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    d = json.loads(q.data)
    if d.get("t") == "mode_switch":
        mode = d.get("m", "auto")
        ctx.user_data["mode"] = mode
        await q.answer(text=f"Режим: {mode.upper()}", show_alert=True)
        await safe_reply(q.message, f"✅ Выбран: {mode}", mode)


async def handle_msg(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    uid, txt = update.effective_user.id, update.message.text or ""
    mode = ctx.user_data.get("mode", "auto")
    loading = await update.message.reply_text("⏳ ...", reply_markup=get_keyboard(mode))
    try:
        async with httpx.AsyncClient(timeout=50) as c:
            r = await c.post(
                f"{API_URL}/process",
                json={"user_id": uid, "text": txt, "force_mode": mode if mode != "auto" else None},
            )
            try:
                d = r.json()
            except:
                d = {"reply": f"⚠️ API:\n{r.text[:300]}", "tag": "[❌]"}
            await loading.delete()
            await safe_reply(update.message, f"{d.get('reply', '')}\n\n{d.get('tag', '')}", mode)
    except Exception as e:
        await loading.delete()
        await safe_reply(update.message, f"⚠️ {str(e)[:100]}", mode)


def main():
    if not BOT_TOKEN:
        return
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(MessageHandler(filters.TEXT, handle_msg))
    app.add_handler(CallbackQueryHandler(handle_cb))
    print("🎨 UI Locked & Bot started")
    app.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    main()
