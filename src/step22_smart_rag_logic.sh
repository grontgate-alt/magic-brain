#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain
cd $BASE

echo "[1/6] Фикс orchestrator.py: авто-ингест + умный роутинг..."
cat << 'PY' > agents/main/orchestrator.py
import os, sys, uuid, json
from pathlib import Path
BASE_DIR = Path(__file__).parent.parent.parent
if str(BASE_DIR) not in sys.path: sys.path.insert(0, str(BASE_DIR))

from rag.router.privacy_router import PrivacyRouter
from rag.embed.local_embedder import LocalEmbedder
from rag.store.qdrant_client import RAGStore
from privacy.local_llm.ollama_client import OllamaClient
from privacy.local_llm.openrouter_client import OpenRouterClient
from agents.critic.critic import Critic
from agents.prompt_opt.optimizer import PromptOptimizer

class MagicBrain:
    def __init__(self):
        self.router = PrivacyRouter()
        self.embedder = LocalEmbedder()
        self.store = RAGStore()
        self.local_llm = OllamaClient()
        self.cloud_llm = OpenRouterClient(api_key=os.getenv("OPENROUTER_API_KEY"), router=self.router)
        self.critic = Critic()
        self.opt = PromptOptimizer()
        self.auto_ingest = os.getenv("AUTO_INGEST_CHAT", "true").lower() == "true"
    
    def _save_to_rag(self, user_query: str, response: str, user_id: int, privacy_level: str):
        """Авто-сохранение диалога в приватный RAG"""
        if not self.auto_ingest: return
        # Сохраняем и вопрос, и ответ как один документ
        text = f"User: {user_query}\nAssistant: {response}"
        meta = {"source": "chat", "user_id": user_id, "privacy": privacy_level, "type": "dialogue"}
        try:
            vec = self.embedder.embed([text])[0]
            self.store.upsert([vec], [meta], [f"chat_{uuid.uuid4().hex[:12]}"])
        except Exception as e:
            print(f"⚠️ RAG ingest error: {e}")
    
    async def process(self, user_query: str, user_id: int, task_type: str = "default") -> dict:
        # 1. Классификация приватности
        mode = self.router.classify(user_query)  # LOCAL / CLOUD
        
        # 2. Поиск в RAG (всегда, но с фильтром приватности)
        query_vec = self.embedder.embed([user_query])[0]
        # Если LOCAL — ищем только HIGH-приватные данные; если CLOUD — любые
        privacy_filter = None if mode == "CLOUD" else "HIGH"
        context = self.store.search(query_vec, limit=5, privacy_filter=privacy_filter)
        ctx_texts = [c["text"] for c in context]
        
        # 3. Проверка: найден ли чувствительный контент (пароли, ключи)
        sensitive_found = any("password" in c.get("meta",{}).get("text","").lower() or 
                             "пароль" in c.get("meta",{}).get("text","") for c in context)
        
        # 4. Оптимизация промпта
        optimized = self.opt.optimize(user_query, task_type)
        
        # 5. Выбор модели
        if mode == "LOCAL":
            response = await self.local_llm.chat(model="qwen2.5:3b", prompt=optimized, context=ctx_texts)
            model_used = "qwen2.5:3b"
        else:
            response = await self.cloud_llm.chat(prompt=optimized, context=ctx_texts)
            model_used = "cloud"  # фактическое имя вернётся из openrouter_client
        
        # 6. Критик
        ok, issues = self.critic.validate(response)
        if not ok:
            return {"error": "Ответ заблокирован критиком", "issues": issues, "privacy_mode": mode, "model_used": model_used, "rag_hits": len(ctx_texts)}
        
        # 7. Если найден чувствительный контент — добавляем подтверждение
        if sensitive_found and "password" in user_query.lower() or "пароль" in user_query:
            response = f"⚠️ В базе найдено сохранённое значение. Показать?\n\n{response}"
        
        # 8. Авто-ингест диалога (если включено)
        self._save_to_rag(user_query, response, user_id, mode)
        
        return {
            "reply": response, 
            "privacy_mode": mode, 
            "context_used": len(ctx_texts), 
            "issues": issues,
            "model_used": model_used,
            "sensitive_found": sensitive_found
        }
PY
echo "✅ orchestrator.py: авто-ингест + умный роутинг"

echo "[2/6] Фикс openrouter_client.py: возврат имени модели..."
sed -i 's/return f"\[{actual_model}\] {text}"/return {"text": text, "model": actual_model}/' privacy/local_llm/openrouter_client.py
sed -i 's/return text/return {"text": text, "model": "unknown"}/' privacy/local_llm/ollama_client.py
echo "✅ Возврат модели из LLM-клиентов"

echo "[3/6] Фикс bot.py: теги + подтверждение..."
cat << 'PY' > interfaces/telegram/bot.py
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
    """Обработка кнопки подтверждения показа секрета"""
    query = update.callback_query
    await query.answer()
    data = json.loads(query.data)
    if data.get("action") == "show_secret":
        # Показываем сохранённое значение (в реальном проде — с доп. проверкой)
        await query.edit_message_text(f"🔐 Сохранённое значение:\n`{data.get('value','[скрыто]')}`", parse_mode="Markdown")
    else:
        await query.edit_message_text("✅ Отменено")

async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uid = update.effective_user.id
    text = update.message.text or ""
    await safe_reply(update, "⏳ Думаю\\.\\.\\.")
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
                
                # Формируем тег
                tag = f"🔐 {model}" if mode=="LOCAL" else f"☁️ {model}"
                if rag_hits > 0: tag += f" +RAG:{rag_hits}"
                
                # Если найден секрет — добавляем кнопку подтверждения
                keyboard = None
                if sensitive and ("пароль" in text.lower() or "password" in text.lower()):
                    keyboard = InlineKeyboardMarkup([[
                        InlineKeyboardButton("✅ Показать", callback_data=json.dumps({"action":"show_secret","value":"[значение из базы]"})),
                        InlineKeyboardButton("❌ Отмена", callback_data=json.dumps({"action":"cancel"}))
                    ]])
                    reply_text = reply_text.split("⚠️ В базе найдено")[0].strip()  # убираем дубликат
                
                reply = f"{reply_text}\n\n\\_\\({tag}\\)"
            await safe_reply(update, reply, keyboard)
    except Exception as e:
        await safe_reply(update, f"⚠️ Ошибка: {str(e)[:100]}")

async def start_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await safe_reply(update, "🦌 Magic Brain\\.\n🔐 Приватность: локальная\\. Всё общение сохраняется в твоём RAG\\.\nПиши что угодно\\.")

def main():
    if not BOT_TOKEN: print("❌ Нет токена"); return
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", start_cmd))
    app.add_handler(MessageHandler(filters.ALL, handle_message))
    app.add_handler(CallbackQueryHandler(handle_confirm))
    print("🤖 Бот запущен"); app.run_polling()

if __name__ == "__main__": main()
PY
echo "✅ bot.py: теги + кнопки подтверждения"

echo "[4/6] Обновление .env: включаем авто-ингест..."
if ! grep -q "AUTO_INGEST_CHAT" $BASE/.env; then
    echo "AUTO_INGEST_CHAT=true" >> $BASE/.env
    echo "✅ AUTO_INGEST_CHAT добавлен"
else
    sed -i 's/AUTO_INGEST_CHAT=.*/AUTO_INGEST_CHAT=true/' $BASE/.env
    echo "✅ AUTO_INGEST_CHAT=true"
fi

echo "[5/6] Перезапуск..."
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

echo "[6/6] Тесты..."
echo "Напиши боту:"
echo "  1. 'привет' → ответ + тег \\_(☁️ ...\\)\\_"
echo "  2. 'сохрани: мой пароль от почты = SuperSecret123' → должно сохраниться в RAG"
echo "  3. 'какой у меня пароль от почты?' → поиск в RAG + кнопка подтверждения"
echo ""
echo "ЖДУ: вывод тестов."
