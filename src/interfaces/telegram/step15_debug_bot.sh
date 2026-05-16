#!/bin/bash
set -e
BASE=~/magic-brain
export PATH="$HOME/.local/bin:$PATH"

echo "=== 1. Проверяем логи API за последнюю минуту ==="
echo "--- /tmp/api.log (последние 40 строк) ---"
tail -40 /tmp/api.log 2>/dev/null || echo "Файл не найден"

echo ""
echo "=== 2. Тестируем /process вручную (с долгим таймаутом) ==="
echo "Запрос 1 (публичный): 'рецепт борща'..."
curl -s -X POST http://127.0.0.1:8000/process \
  -H "Content-Type: application/json" \
  --max-time 120 \
  -d '{"user_id":1,"text":"рецепт борща","task_type":"default"}' | python3 -m json.tool 2>/dev/null || echo "⚠️ Таймаут/ошибка"

echo ""
echo "Запрос 2 (приватный): 'дай пароль от почты'..."
curl -s -X POST http://127.0.0.1:8000/process \
  -H "Content-Type: application/json" \
  --max-time 120 \
  -d '{"user_id":1,"text":"дай пароль от почты","task_type":"default"}' | python3 -m json.tool 2>/dev/null || echo "⚠️ Таймаут/ошибка"

echo ""
echo "=== 3. Фикс бота: показываем понятные ошибки ==="
cat << 'PY' > $BASE/interfaces/telegram/bot.py
import os, sys, logging, asyncio, json
from pathlib import Path
BASE = Path(__file__).parent.parent.parent
if str(BASE) not in sys.path: sys.path.insert(0, str(BASE))

from telegram import Update
from telegram.ext import Application, CommandHandler, MessageHandler, filters, ContextTypes
import httpx

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

API_URL = os.getenv("API_BRIDGE_URL", "http://localhost:8000")
BOT_TOKEN = os.getenv("TG_BOT_TOKEN", "")

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(
        "🦌 *Magic Brain* готов.\n"
        "🔐 Приватность: STRICT\n"
        "📁 Отправляй текст/файлы.\n"
        "Команды:\n"
        "/save <текст> — сохранить в RAG\n"
        "/ask <вопрос> — запрос к базе + ИИ",
        parse_mode="Markdown"
    )

async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uid = update.effective_user.id
    text = update.message.text or ""
    has_file = bool(update.message.document)
    
    await update.message.reply_text("⏳ Думаю...")
    
    try:
        async with httpx.AsyncClient(timeout=120.0) as c:
            payload = {"user_id": uid, "text": text, "has_files": has_file}
            r = await c.post(f"{API_URL}/process", json=payload)
            result = r.json()
            
            # Обработка ответа
            if "error" in result:
                err = result.get("error", "Неизвестная ошибка")
                trace = result.get("trace", "")
                if "Qdrant" in err or "embed" in err.lower():
                    reply = "⚠️ Ошибка RAG: база ещё не готова. Попробуй позже."
                elif "timeout" in err.lower() or "time" in trace.lower():
                    reply = "⏱️ Таймаут: модель загружается. Повтори через 30 сек."
                else:
                    reply = f"⚠️ Ошибка: {err[:200]}"
            else:
                reply = result.get("reply", "✅ Обработано")
                mode = result.get("privacy_mode", "")
                if mode == "LOCAL":
                    reply = f"🔐 [Локально] {reply}"
                elif mode == "CLOUD":
                    reply = f"☁️ [Облако] {reply}"
            
            await update.message.reply_text(reply, parse_mode="Markdown")
            
    except httpx.TimeoutException:
        await update.message.reply_text("⏱️ Таймаут: запрос сложный, модель грузится. Повтори через 30 сек.")
    except httpx.ConnectError:
        await update.message.reply_text("🔌 Не могу подключиться к ядру. Проверь, запущен ли API.")
    except Exception as e:
        logger.error(f"Bot error: {e}")
        await update.message.reply_text(f"⚠️ Ошибка бота: {str(e)[:150]}")

def main():
    if not BOT_TOKEN or BOT_TOKEN == "YOUR_TOKEN_HERE":
        print("❌ Укажи TG_BOT_TOKEN: export TG_BOT_TOKEN=xxx")
        return
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(MessageHandler(filters.ALL, handle_message))
    print(f"🤖 Бот запущен. Токен: {BOT_TOKEN[:10]}...")
    app.run_polling()

if __name__ == "__main__":
    main()
PY
echo "✅ Бот обновлён"

echo ""
echo "=== 4. Перезапуск бота ==="
pkill -f "python3.*bot.py" 2>/dev/null || true
sleep 2
echo "Запусти бота вручную:"
echo "  export TG_BOT_TOKEN=xxx"
echo "  cd $BASE/interfaces/telegram && python3 bot.py"

echo ""
echo "=== 5. Что означают ответы ==="
echo "• 'рецепт борща' → должен вернуть рецепт (может занять 30-60 сек первый раз)"
echo "• 'дай пароль' → правильный ответ: отказ выдать секрет (критик/локальная модель)"
echo "  Если пришёл 'длинный текст с отказом' — это ✅ система работает!"

echo ""
echo "📍 Если /process таймаутится — это нормально при первом вызове (загрузка BGE-m3 ~1.2 ГБ в память)."
echo "Последующие запросы будут быстрее."
echo ""
echo "ЖДУ: вывод ручных тестов /process или подтверждение, что бот работает."
