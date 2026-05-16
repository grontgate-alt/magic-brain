#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain

echo "[1/3] Фикс main.py: возвращаем имя модели..."
# Добавляем model_used в ответ process
sed -i 's/return {"reply": response, "privacy_mode": mode, "context_used": len(ctx_texts), "issues": issues}/return {"reply": response, "privacy_mode": mode, "context_used": len(ctx_texts), "issues": issues, "model_used": "cloud" if mode=="CLOUD" else "qwen2.5:3b"}/' $BASE/agents/main/orchestrator.py
# Для облака подставим реальное имя из ответа OpenRouter
sed -i 's/return f"\[{actual_model}\] {text}"/return {"text": text, "model": actual_model}/' $BASE/privacy/local_llm/openrouter_client.py
echo "✅ orch и openrouter обновлены"

echo "[2/3] Фикс bot.py: показываем модель..."
cat << 'PY' > $BASE/interfaces/telegram/bot.py
import os, sys, logging, re
from pathlib import Path
BASE = Path(__file__).parent.parent.parent
if str(BASE) not in sys.path: sys.path.insert(0, str(BASE))
from telegram import Update
from telegram.ext import Application, CommandHandler, MessageHandler, filters, ContextTypes
from telegram.error import BadRequest
import httpx, json

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
API_URL = os.getenv("API_BRIDGE_URL", "http://localhost:8000")
BOT_TOKEN = os.getenv("TG_BOT_TOKEN", "")

def esc(text: str) -> str:
    return re.sub(r'([_*[\]~`>#+\-=|{}.!])', r'\\\1', str(text))

async def safe_reply(update: Update, text: str):
    try: await update.message.reply_text(esc(text), parse_mode="MarkdownV2")
    except BadRequest: await update.message.reply_text(text)

async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uid = update.effective_user.id
    text = update.message.text or ""
    await safe_reply(update, "⏳ Думаю\\.\\.\\.")
    try:
        async with httpx.AsyncClient(timeout=120.0) as c:
            r = await c.post(f"{API_URL}/process", json={"user_id":uid, "text":text, "has_files":False, "task_type":"default"})
            res = r.json()
            if "error" in res: reply = f"⚠️ {res['error'][:150]}"
            else:
                mode = res.get("privacy_mode","")
                model = res.get("model_used","")
                reply_text = res.get("reply","")
                tag = "🔐 Локал" if mode=="LOCAL" else f"☁️ {model}"
                reply = f"{reply_text}\n\n\\_\\({tag}\\)"
            await safe_reply(update, reply)
    except Exception as e:
        await safe_reply(update, f"⚠️ Ошибка: {str(e)[:100]}")

def main():
    if not BOT_TOKEN: print("❌ Нет токена"); return
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", lambda u,c: safe_reply(u, "🦌 Magic Brain готов\\. Пиши что угодно\\.")))
    app.add_handler(MessageHandler(filters.ALL, handle_message))
    print("🤖 Бот запущен"); app.run_polling()

if __name__ == "__main__": main()
PY
echo "✅ bot.py обновлён"

echo "[3/3] Перезапуск..."
pkill -f "uvicorn|bot.py" 2>/dev/null || true; sleep 3
set -a; source $BASE/.env; set +a
cd $BASE/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health > /dev/null && echo "✅ API UP" || echo "❌ API DOWN"

cd $BASE/interfaces/telegram
TG_BOT_TOKEN="$TG_BOT_TOKEN" API_BRIDGE_URL="http://127.0.0.1:8000" \
nohup python3 bot.py > /tmp/bot.log 2>&1 &
sleep 3
grep "Бот запущен" /tmp/bot.log && echo "✅ Бот UP" || echo "⚠️ Проверь лог"

echo ""
echo "Тест: напиши боту 'привет' и 'пароль от почты'."
echo "Внизу сообщения будет тег: \\_(☁️ qwen-2.5-7b-instruct:free)\\_ или \\_(🔐 Локал)\\_"
echo "ЖДУ: ОК или вывод ошибки."
