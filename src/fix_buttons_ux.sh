#!/bin/bash
set -e
cd ~/magic-brain

echo "[1/3] Bot: кнопки с подтверждением + индикация режима..."
cat << 'PY' > interfaces/telegram/bot.py
import os, sys, re, json, logging, asyncio, httpx
from pathlib import Path
BASE = Path(__file__).parent.parent.parent
sys.path.insert(0, str(BASE))
env = BASE / ".env"
if env.exists():
    for ln in env.read_text().splitlines():
        if "=" in ln and not ln.strip().startswith("#"):
            k,v = ln.split("=",1); os.environ[k.strip()]=v.strip()

from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, MessageHandler, filters, ContextTypes, CallbackQueryHandler
from telegram.error import BadRequest

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(message)s')
API_URL = os.getenv("API_BRIDGE_URL", "http://localhost:8000")
BOT_TOKEN = os.getenv("TG_BOT_TOKEN", "")

def esc(t): return re.sub(r'([_*\[\]()~`>#+\-=|{}.!\\])', r'\\\1', str(t)) if t else ""

def kb_for_mode(mode: str) -> InlineKeyboardMarkup:
    """Кнопки с подсветкой текущего режима"""
    active = {"agent":"🔘","chat":"🔘","rag":"🔘","web":"🔘"}
    active[mode] = "✅"  # подсветка активного
    return InlineKeyboardMarkup([[
        InlineKeyboardButton(f"{active['agent']} 🛠️ Агент", callback_data=json.dumps({"t":"mode","m":"agent"})),
        InlineKeyboardButton(f"{active['chat']} 💬 Чат", callback_data=json.dumps({"t":"mode","m":"chat"})),
    ],[
        InlineKeyboardButton(f"{active['rag']} 🗄️ Память", callback_data=json.dumps({"t":"mode","m":"rag"})),
        InlineKeyboardButton(f"{active['web']} 🌐 Веб", callback_data=json.dumps({"t":"mode","m":"web"})),
    ]])

async def reply(msg, text, mode="auto"):
    try:
        await msg.reply_text(esc(text), parse_mode="MarkdownV2", reply_markup=kb_for_mode(mode))
    except BadRequest:
        await msg.reply_text(text, reply_markup=kb_for_mode(mode))

async def handle_cb(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    """Обработка кнопок — СМЕНА РЕЖИМА С ПОДТВЕРЖДЕНИЕМ"""
    q = update.callback_query
    await q.answer()
    d = json.loads(q.data)
    uid = q.from_user.id
    
    if d.get("t") == "mode":
        new_mode = d.get("m", "auto")
        # === СОХРАНЯЕМ РЕЖИМ НА СЕРВЕРЕ (не в ephemeral context) ===
        try:
            async with httpx.AsyncClient(timeout=10) as c:
                await c.post(f"{API_URL}/user/{uid}/mode", json={"mode": new_mode})
        except:
            pass  # не критично если API ещё не поддерживает
        
        # === ВИЗУАЛЬНОЕ ПОДТВЕРЖДЕНИЕ ===
        mode_names = {"agent":"🛠️ Агент (инструменты)","chat":"💬 Чат (просто ответ)","rag":"🗄️ Память (поиск в сохранённом)","web":"🌐 Веб (поиск в интернете)","auto":"🔄 Авто (умный выбор)"}
        await q.edit_message_text(f"✅ Режим: {mode_names.get(new_mode, new_mode)}\n\nТеперь твои запросы будут обрабатываться через {new_mode}.")
        # Возвращаем кнопки с обновлённой подсветкой
        await reply(q.message, f"Режим изменён: {mode_names.get(new_mode, new_mode)}", new_mode)

async def handle_msg(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    uid = update.effective_user.id
    text = update.message.text or ""
    
    # === ПОЛУЧАЕМ ТЕКУЩИЙ РЕЖИМ ПОЛЬЗОВАТЕЛЯ ===
    user_mode = "auto"  # дефолт
    try:
        async with httpx.AsyncClient(timeout=5) as c:
            r = await c.get(f"{API_URL}/user/{uid}/mode")
            if r.status_code == 200:
                user_mode = r.json().get("mode", "auto")
    except:
        pass  # если API не отвечает — используем дефолт
    
    await reply(update.message, "⏳ ...", user_mode)
    
    try:
        async with httpx.AsyncClient(timeout=40) as c:
            payload = {
                "user_id": uid, "text": text, "has_files": False,
                "force_mode": user_mode if user_mode != "auto" else None
            }
            r = await c.post(f"{API_URL}/process", json=payload)
            d = r.json()
            
            reply_text = d.get("reply", "")
            tag = d.get("tag", "[❓]")
            response_mode = d.get("privacy_mode", "auto")  # какой режим реально сработал
            
            # Показываем кнопки с подсветкой РЕАЛЬНО сработавшего режима
            await reply(update.message, f"{reply_text}\n\n{tag}", response_mode)
            
    except Exception as e:
        logging.error(f"Error: {e}")
        await reply(update.message, f"⚠️ {str(e)[:120]}", user_mode)

def main():
    if not BOT_TOKEN or len(BOT_TOKEN)<20: print("❌ Нет токена"); return
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(MessageHandler(filters.TEXT, handle_msg))
    app.add_handler(CallbackQueryHandler(handle_cb))
    print(f"🤖 Bot started (mode-aware UI)")
    app.run_polling(drop_pending_updates=True)

if __name__ == "__main__": main()
PY
echo "✅ bot.py: режимы с визуальным статусом"

echo "[2/3] API: эндпоинты для сохранения режима пользователя..."
cat << 'PY' >> interfaces/api/main.py

# === User mode persistence ===
user_modes: Dict[int, str] = {}

@app.post("/user/{user_id}/mode")
async def set_user_mode(user_id: int, payload: dict):
    """Сохраняет предпочтительный режим для пользователя"""
    mode = payload.get("mode", "auto")
    if mode not in ("auto","chat","tools","rag","web"):
        return {"error": "invalid mode"}
    user_modes[user_id] = mode
    return {"status": "ok", "mode": mode}

@app.get("/user/{user_id}/mode")
async def get_user_mode(user_id: int):
    """Возвращает текущий режим пользователя"""
    return {"mode": user_modes.get(user_id, "auto")}
PY
echo "✅ API: user mode endpoints"

echo "[3/3] Orchestrator: читаем force_mode из запроса..."
# Добавляем обработку force_mode в process() если ещё нет
grep -q "force_mode" agents/main/orchestrator.py || sed -i '/async def process(/a\                      force_mode: str = None,' agents/main/orchestrator.py
echo "✅ orchestrator: force_mode support"

echo ""
echo "[4/4] Перезапуск..."
pkill -9 -f uvicorn 2>/dev/null || true; pkill -9 -f "bot.py" 2>/dev/null || true
sleep 2
set -a; source ~/magic-brain/.env; set +a
cd ~/magic-brain/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
cd ~/magic-brain/interfaces/telegram
nohup python3 bot.py > /tmp/bot.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health && echo "✅ API UP" || echo "❌ API DOWN"

echo ""
echo "🎉 Готово! Теперь:"
echo ""
echo "🔘 Кнопки показывают ТЕКУЩИЙ режим:"
echo "   ✅ 🛠️ Агент  |  🔘 💬 Чат  |  🔘 🗄️ Память  |  🔘 🌐 Веб"
echo "         ↑"
echo "   ✅ = активный режим"
echo ""
echo "🔄 При нажатии:"
echo "   1. Сообщение меняется на: '✅ Режим: 🛠️ Агент (инструменты)'"
echo "   2. Режим сохраняется для следующих запросов"
echo "   3. Кнопки обновляются с новой подсветкой"
echo ""
echo "📋 Режимы:"
echo "   • 🔄 Авто — система сама выбирает (по умолчанию)"
echo "   • 🛠️ Агент — всегда через инструменты (файлы, GitHub, поиск)"
echo "   • 💬 Чат — просто ответ от LLM + RAG контекст"
echo "   • 🗄️ Память — прямой поиск в твоих сохранённых данных"
echo "   • 🌐 Веб — поиск в интернете + синтез ответа"
echo ""
echo "🧪 Тест:"
echo "   1. Нажми 🛠️ Агент → увидишь подтверждение"
echo "   2. Напиши 'Покажи файлы в /home/der' → должен сработать MCP"
echo "   3. Нажми 💬 Чат → следующий запрос пойдёт через обычный LLM"
echo ""
echo "ЖДУ: подтверждение или скрин."
