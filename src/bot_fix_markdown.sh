#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain

echo "[1/3] Фикс бота: безопасный Markdown + fallback на plain text..."
cat << 'PY' > $BASE/interfaces/telegram/bot.py
import os, sys, logging, asyncio, re
from pathlib import Path
BASE = Path(__file__).parent.parent.parent
if str(BASE) not in sys.path: sys.path.insert(0, str(BASE))

from telegram import Update
from telegram.ext import Application, CommandHandler, MessageHandler, filters, ContextTypes
from telegram.error import BadRequest
import httpx

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

API_URL = os.getenv("API_BRIDGE_URL", "http://localhost:8000")
BOT_TOKEN = os.getenv("TG_BOT_TOKEN", "")

def escape_markdown_v2(text: str) -> str:
    """Экранирует спецсимволы MarkdownV2 для Telegram"""
    if not text: return text
    # Символы, требующие экранирования в MarkdownV2
    chars = r'[_*[\]~`>#+\-=|{}.!]'
    return re.sub(f'({chars})', r'\\\1', text)

async def safe_reply(update: Update, text: str, parse_mode: str = "MarkdownV2"):
    """Отправляет сообщение с безопасным парсингом"""
    try:
        if parse_mode == "MarkdownV2":
            text = escape_markdown_v2(text)
        await update.message.reply_text(text, parse_mode=parse_mode)
    except BadRequest as e:
        if "Can't parse entities" in str(e):
            # Fallback: plain text без разметки
            await update.message.reply_text(text, parse_mode=None)
        else:
            raise

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await safe_reply(update, "🦌 *Magic Brain* готов\\.\n🔐 Приватность: STRICT\n📁 Отправляй текст/файлы\\.\nКоманды:\n`/save <текст>` — сохранить в RAG\n`/ask <вопрос>` — запрос к базе \\+ ИИ", parse_mode="MarkdownV2")

async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uid = update.effective_user.id
    text = update.message.text or ""
    has_file = bool(update.message.document)
    
    await safe_reply(update, "⏳ Думаю\\.", parse_mode="MarkdownV2")
    
    try:
        async with httpx.AsyncClient(timeout=120.0) as c:
            payload = {"user_id": uid, "text": text, "has_files": has_file}
            r = await c.post(f"{API_URL}/process", json=payload)
            result = r.json()
            
            if "error" in result:
                err = result.get("error", "Неизвестная ошибка")
                if "Qdrant" in err or "embed" in err.lower():
                    reply = "⚠️ Ошибка RAG: база ещё не готова\\. Попробуй позже\\."
                elif "timeout" in err.lower():
                    reply = "⏱️ Таймаут: модель загружается\\. Повтори через 30 сек\\."
                else:
                    reply = f"⚠️ Ошибка: {err[:180]}"
            else:
                reply = result.get("reply", "✅ Обработано")
                mode = result.get("privacy_mode", "")
                if mode == "LOCAL":
                    reply = f"🔐 \\[Локально\\] {reply}"
                elif mode == "CLOUD":
                    reply = f"☁️ \\[Облако\\] {reply}"
            
            await safe_reply(update, reply, parse_mode="MarkdownV2")
            
    except httpx.TimeoutException:
        await safe_reply(update, "⏱️ Таймаут: запрос сложный, модель грузится\\. Повтори через 30 сек\\.", parse_mode="MarkdownV2")
    except httpx.ConnectError:
        await safe_reply(update, "🔌 Не могу подключиться к ядру\\. Проверь, запущен ли API\\.", parse_mode="MarkdownV2")
    except Exception as e:
        logger.error(f"Bot error: {e}")
        await safe_reply(update, f"⚠️ Ошибка бота: {str(e)[:140]}", parse_mode=None)

def main():
    if not BOT_TOKEN or BOT_TOKEN == "YOUR_TOKEN_HERE":
        print("❌ Укажи TG_BOT_TOKEN: export TG_BOT_TOKEN=xxx")
        return
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(MessageHandler(filters.ALL, handle_message))
    print(f"🤖 Бот запущен\\. Токен: {BOT_TOKEN[:10]}\\.\\.\\.")
    app.run_polling()

if __name__ == "__main__":
    main()
PY
echo "✅ bot.py обновлён (безопасный Markdown)"

echo "[2/3] Перезапуск бота..."
pkill -f "python3.*bot.py" 2>/dev/null || true
sleep 2
cd $BASE/interfaces/telegram
TG_BOT_TOKEN="$TG_BOT_TOKEN" API_BRIDGE_URL="http://127.0.0.1:8000" \
nohup python3 bot.py > /tmp/bot.log 2>&1 &
sleep 3
grep "Application started" /tmp/bot.log && echo "✅ Бот в фоне" || echo "⚠️ Проверь /tmp/bot.log"

echo "[3/3] Тест..."
echo "Напиши боту в Telegram:"
echo "  • 'привет' — должен ответить"
echo "  • 'пароль от почты' — должен ответить с 🔐"
echo "  • 'рецепт борща' — рецепт (10-20 сек)"
echo ""
echo "Если ошибка — скинь /tmp/bot.log"
