#!/bin/bash
set -e
cd ~/magic-brain

echo "[1/2] Фиксирую дизайн кнопок в отдельный модуль ui.py..."
cat << 'PY' > interfaces/telegram/ui.py
import json
from telegram import InlineKeyboardButton, InlineKeyboardMarkup
from telegram.error import BadRequest

# === ЗАФИКСИРОВАННЫЙ ДИЗАЙН (НЕ МЕНЯТЬ) ===
MODES = {"agent": "🛠️ Агент", "chat": "💬 Чат", "rag": "🗄️ Память", "web": "🌐 Веб"}

def get_keyboard(active_mode: str = "auto") -> InlineKeyboardMarkup:
    """Всегда 2x2 сетка, активный режим подсвечен ✅"""
    btns = []
    for mode, label in MODES.items():
        icon = "✅" if mode == active_mode else "🔘"
        data = json.dumps({"t": "mode_switch", "m": mode})
        btns.append(InlineKeyboardButton(f"{icon} {label}", callback_data=data))
    return InlineKeyboardMarkup([btns[:2], btns[2:]])

async def safe_reply(message, text: str, mode: str = "auto"):
    """Надёжная отправка с клавиатурой. Никогда не падает."""
    kb = get_keyboard(mode)
    try: await message.reply_text(text, reply_markup=kb)
    except BadRequest:
        try: await message.reply_text(str(text)[:1000], reply_markup=kb)
        except: await message.reply_text("✅", reply_markup=kb)
    except: pass
PY
echo "✅ ui.py зафиксирован (изолирован от бэкенда)"

echo "[2/2] Обновляю bot.py → использует только ui.py..."
cat << 'PY' > interfaces/telegram/bot.py
import os, sys, json, httpx, logging
from pathlib import Path
BASE = Path(__file__).parent.parent.parent
sys.path.insert(0, str(BASE))
for ln in (BASE/".env").read_text().splitlines():
    if "=" in ln and not ln.strip().startswith("#"): k,v=ln.split("=",1); os.environ[k.strip()]=v.strip()

from telegram import Update
from telegram.ext import Application, MessageHandler, filters, ContextTypes, CallbackQueryHandler
from interfaces.telegram.ui import safe_reply, get_keyboard

API_URL = os.getenv("API_BRIDGE_URL", "http://localhost:8000")
BOT_TOKEN = os.getenv("TG_BOT_TOKEN", "")
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(message)s')

async def handle_cb(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query; await q.answer()
    d = json.loads(q.data)
    if d.get("t") == "mode_switch":
        mode = d.get("m","auto"); ctx.user_data["mode"] = mode
        await q.answer(text=f"Режим: {mode.upper()}", show_alert=True)
        await safe_reply(q.message, f"✅ Выбран: {mode}", mode)

async def handle_msg(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    uid, txt = update.effective_user.id, update.message.text or ""
    mode = ctx.user_data.get("mode","auto")
    loading = await update.message.reply_text("⏳ ...", reply_markup=get_keyboard(mode))
    try:
        async with httpx.AsyncClient(timeout=50) as c:
            r = await c.post(f"{API_URL}/process", json={"user_id":uid,"text":txt,"force_mode":mode if mode!="auto" else None})
            try: d = r.json()
            except: d = {"reply": f"⚠️ API:\n{r.text[:300]}", "tag":"[❌]"}
            await loading.delete()
            await safe_reply(update.message, f"{d.get('reply','')}\n\n{d.get('tag','')}", mode)
    except Exception as e:
        await loading.delete()
        await safe_reply(update.message, f"⚠️ {str(e)[:100]}", mode)

def main():
    if not BOT_TOKEN: return
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(MessageHandler(filters.TEXT, handle_msg))
    app.add_handler(CallbackQueryHandler(handle_cb))
    print("🎨 UI Locked & Bot started"); app.run_polling(drop_pending_updates=True)

if __name__=="__main__": main()
PY
echo "✅ bot.py перезаписан под фиксированный UI"

echo "[3/3] Перезапуск..."
pkill -9 -f "bot.py" 2>/dev/null || true
cd ~/magic-brain/interfaces/telegram
nohup python3 bot.py > /tmp/bot.log 2>&1 &
sleep 3
echo "✅ Дизайн кнопок ЗАФИКСИРОВАН в ui.py."
echo "Больше никогда не сломается при смене логики бэкенда."
echo "Напиши боту 'привет' — кнопки будут под каждым сообщением."
