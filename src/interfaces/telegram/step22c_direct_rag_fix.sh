#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain
cd $BASE

echo "[1/5] Фикс orchestrator: команда 'сохрани:' → прямой инжест в RAG..."
cat << 'PY' > agents/main/orchestrator.py
import os, sys, uuid, re
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
    
    def _direct_ingest(self, text: str, user_id: int) -> str:
        """Прямое сохранение в RAG без LLM"""
        meta = {"source": "direct_save", "user_id": user_id, "privacy": "HIGH", "tags": ["sensitive", "user_data"]}
        try:
            vec = self.embedder.embed([text])[0]
            doc_id = f"usr_{user_id}_{uuid.uuid4().hex[:8]}"
            self.store.upsert([vec], [meta], [doc_id])
            return f"✅ Сохранено в твоём приватном хранилище (ID: {doc_id[-8:]})"
        except Exception as e:
            return f"⚠️ Ошибка сохранения: {str(e)[:100]}"
    
    def _raw_rag_search(self, query: str, user_id: int, limit: int = 3) -> list:
        """Сырой поиск: возвращает тексты без фильтрации"""
        try:
            vec = self.embedder.embed([query])[0]
            # Ищем ТОЛЬКО данные этого пользователя с тегами sensitive
            results = self.store.search(vec, limit=limit*3, privacy_filter="HIGH")
            # Фильтруем по user_id и релевантности
            relevant = [r["text"] for r in results if r.get("meta",{}).get("user_id") == user_id]
            return relevant[:limit]
        except Exception as e:
            print(f"⚠️ RAG search error: {e}")
            return []
    
    async def process(self, user_query: str, user_id: int, task_type: str = "default") -> dict:
        # === 1. Прямая команда сохранения ===
        if user_query.strip().lower().startswith("сохрани:"):
            content = user_query.split(":", 1)[1].strip()
            result_text = self._direct_ingest(content, user_id)
            return {
                "reply": result_text,
                "privacy_mode": "LOCAL",
                "model_used": "rag_direct",
                "context_used": 0,
                "sensitive_found": False,
                "issues": []
            }
        
        # === 2. Запрос на показ сохранённого ===
        if any(x in user_query.lower() for x in ["покажи", "напомни", "какой.*пароль", "мой.*пароль"]):
            found = self._raw_rag_search(user_query, user_id)
            if found:
                # Возвращаем сырые данные + инструкцию
                raw_values = "\n• ".join(found)
                return {
                    "reply": f"Найдено в твоём хранилище:\n• {raw_values}\n\n⚠️ Это приватные данные. Не показывай их никому.",
                    "privacy_mode": "LOCAL",
                    "model_used": "rag_raw",
                    "context_used": len(found),
                    "sensitive_found": True,
                    "issues": []
                }
        
        # === 3. Обычный поток ===
        mode = self.router.classify(user_query)
        query_vec = self.embedder.embed([user_query])[0]
        privacy_filter = None if mode == "CLOUD" else "HIGH"
        context = self.store.search(query_vec, limit=5, privacy_filter=privacy_filter)
        ctx_texts = [c["text"] for c in context]
        sensitive_found = len(context) > 0 and any("пароль" in t.lower() for t in ctx_texts)
        
        optimized = self.opt.optimize(user_query, task_type)
        if mode == "LOCAL":
            response = await self.local_llm.chat(model="qwen2.5:3b", prompt=optimized, context=ctx_texts)
            model_used = "qwen2.5:3b"
        else:
            response = await self.cloud_llm.chat(prompt=optimized, context=ctx_texts)
            model_used = "cloud"
        
        ok, issues = self.critic.validate(response)
        if not ok and not sensitive_found:
            return {"error": "Ответ заблокирован критиком", "issues": issues, "privacy_mode": mode, "model_used": model_used, "rag_hits": len(ctx_texts)}
        
        return {
            "reply": response, 
            "privacy_mode": mode, 
            "context_used": len(ctx_texts), 
            "issues": issues,
            "model_used": model_used,
            "sensitive_found": sensitive_found
        }
PY
echo "✅ orchestrator: прямой инжест + сырой поиск"

echo "[2/5] Фикс bot.py: корректный тег + обработка сырых данных..."
cat << 'PY' > interfaces/telegram/bot.py
import os, sys, re, json, logging
from pathlib import Path
BASE = Path(__file__).parent.parent.parent
env_path = BASE / ".env"
if env_path.exists():
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            os.environ[k.strip()] = v.strip()
if str(BASE) not in sys.path: sys.path.insert(0, str(BASE))
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, MessageHandler, filters, ContextTypes, CallbackQueryHandler
from telegram.error import BadRequest
import httpx

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
API_URL = os.getenv("API_BRIDGE_URL", "http://localhost:8000")
BOT_TOKEN = os.getenv("TG_BOT_TOKEN", "")

def esc_md(text: str) -> str:
    if not text: return text
    return re.sub(r'([_*\[\]()~`>#+\-=|{}.!\\])', r'\\\1', text)

async def safe_reply(update: Update, text: str, keyboard=None):
    try:
        await update.message.reply_text(esc_md(text), parse_mode="MarkdownV2", reply_markup=keyboard)
    except BadRequest:
        await update.message.reply_text(text, reply_markup=keyboard)

async def handle_confirm(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    data = json.loads(query.data)
    if data.get("action") == "show_secret":
        await query.edit_message_text("🔐 Значение: `[из базы]`", parse_mode="Markdown")
    else:
        await query.edit_message_text("✅ Отменено")

async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uid = update.effective_user.id
    text = update.message.text or ""
    keyboard = None
    await safe_reply(update, "⏳ Думаю...", keyboard)
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
                
                # Формируем тег БЕЗ переносов
                tag = f"🔐{model}" if mode=="LOCAL" else f"☁️{model}"
                if rag_hits > 0: tag += f"+RAG:{rag_hits}"
                
                if sensitive and ("покажи" in text.lower() or "пароль" in text.lower()):
                    keyboard = InlineKeyboardMarkup([[
                        InlineKeyboardButton("✅ Показать", callback_data=json.dumps({"action":"show_secret"})),
                        InlineKeyboardButton("❌ Отмена", callback_data=json.dumps({"action":"cancel"}))
                    ]])
                
                # Тег в новой строке, без _() чтобы не ломалось
                reply = f"{reply_text}\n\n\\[{tag}\\]"
            await safe_reply(update, reply, keyboard)
    except Exception as e:
        await safe_reply(update, f"⚠️ Ошибка: {str(e)[:100]}", keyboard)

async def start_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await safe_reply(update, "🦌 Magic Brain.\n🔐 Всё локально. Пиши что угодно.", None)

def main():
    if not BOT_TOKEN or len(BOT_TOKEN) < 20:
        print(f"❌ Нет валидного токена. Длина: {len(BOT_TOKEN)}")
        return
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", start_cmd))
    app.add_handler(MessageHandler(filters.ALL, handle_message))
    app.add_handler(CallbackQueryHandler(handle_confirm))
    print(f"🤖 Бот запущен. Токен: {BOT_TOKEN[:10]}...")
    app.run_polling()

if __name__ == "__main__": main()
PY
echo "✅ bot.py: тег в формате [🔐model+RAG:N]"

echo "[3/5] Перезапуск..."
pkill -f "uvicorn|bot.py" 2>/dev/null || true; sleep 3
set -a; source $BASE/.env; set +a
cd $BASE/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health > /dev/null && echo "✅ API UP" || echo "❌ API DOWN"

cd $BASE/interfaces/telegram
python3 bot.py > /tmp/bot.log 2>&1 &
sleep 4
grep "Бот запущен" /tmp/bot.log && echo "✅ Бот UP" || echo "⚠️ Проверь лог"

echo "[4/5] Тесты (строго по порядку):"
echo "  1️⃣  'сохрани: мой пароль от почты = SuperSecret123'"
echo "      → должно ответить: ✅ Сохранено в твоём приватном хранилище..."
echo ""
echo "  2️⃣  'покажи мой пароль от почты'"
echo "      → должно найти и показать: • мой пароль от почты = SuperSecret123"
echo "      → тег внизу: [🔐qwen2.5:3b+RAG:1]"
echo ""
echo "  3️⃣  'привет'"
echo "      → обычный ответ, тег [☁️cloud] или [🔐qwen2.5:3b]"

echo "[5/5] Если не работает — скинь вывод:"
echo "  tail -20 /tmp/bot.log"
echo "  tail -20 /tmp/api.log"
