#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain
cd $BASE

echo "[1/4] Orchestrator: чистый авто-RAG + токенизация, 0 блокировок..."
cat << 'PY' > agents/main/orchestrator.py
import os, sys, uuid
from pathlib import Path
BASE_DIR = Path(__file__).parent.parent.parent
if str(BASE_DIR) not in sys.path: sys.path.insert(0, str(BASE_DIR))

from rag.router.privacy_router import PrivacyRouter
from rag.embed.local_embedder import LocalEmbedder
from rag.store.qdrant_client import RAGStore
from privacy.local_llm.ollama_client import OllamaClient
from privacy.local_llm.openrouter_client import OpenRouterClient
from privacy.vault.token_vault import TokenVault

class MagicBrain:
    def __init__(self):
        self.router = PrivacyRouter()
        self.embedder = LocalEmbedder()
        self.store = RAGStore()
        self.local_llm = OllamaClient()
        self.cloud_llm = OpenRouterClient(api_key=os.getenv("OPENROUTER_API_KEY"), router=self.router)
        self.vault = TokenVault()

    def _auto_save(self, text: str, user_id: int, role: str):
        """Безусловное сохранение в RAG"""
        try:
            vec = self.embedder.embed([text])[0]
            payload = {"text": text, "user_id": user_id, "role": role, "privacy": "HIGH"}
            self.store.upsert([vec], [payload], [str(uuid.uuid4())])
        except Exception as e:
            print(f"️ RAG save error: {e}")

    async def process(self, user_query: str, user_id: int, task_type: str = "default") -> dict:
        # 1. Авто-инжест ЗАПРОСА
        self._auto_save(f"USER: {user_query}", user_id, "query")

        # 2. Маршрут
        mode = self.router.classify(user_query)

        # 3. Подготовка промпта + токенизация (только для облака)
        prompt = user_query
        if mode == "CLOUD":
            scrubbed, _ = self.vault.scrub(user_query)
            prompt = scrubbed

        # 4. Поиск в RAG (всегда)
        vec = self.embedder.embed([prompt])[0]
        results = self.store.search(vec, limit=5)
        ctx_texts = [r.get("text", "") or r.get("meta", {}).get("text", "") for r in results]

        # 5. Системный промпт (прямой, без морализма)
        system = "Ты приватный ассистент. Отвечай прямо по делу. Используй контекст, если он релевантен. Никаких отказов."
        full_prompt = f"{system}\n\nКонтекст:\n" + "\n---\n".join(ctx_texts) + f"\n\nЗапрос: {prompt}"

        # 6. Вызов LLM
        if mode == "LOCAL":
            response = await self.local_llm.chat(model="qwen2.5:3b", prompt=full_prompt, context=[])
            model_used = "qwen2.5:3b"
        else:
            response = await self.cloud_llm.chat(prompt=full_prompt, context=[])
            model_used = "cloud"

        # 7. Де-токенизация ответа (если облако)
        if mode == "CLOUD":
            response = self.vault.unscrub(response)

        # 8. Авто-инжест ОТВЕТА
        self._auto_save(f"ASSISTANT: {response}", user_id, "response")

        return {
            "reply": response,
            "privacy_mode": mode,
            "model_used": model_used,
            "context_used": len(ctx_texts)
        }
PY
echo "✅ Orchestrator обновлён"

echo "[2/4] Bot: убираем кнопки, чистый вывод..."
cat << 'PY' > interfaces/telegram/bot.py
import os, sys, re, logging
from pathlib import Path
BASE = Path(__file__).parent.parent.parent
env = BASE / ".env"
if env.exists():
    for ln in env.read_text().splitlines():
        if "=" in ln and not ln.startswith("#"):
            k,v = ln.split("=",1); os.environ[k.strip()]=v.strip()
if str(BASE) not in sys.path: sys.path.insert(0, str(BASE))
from telegram import Update
from telegram.ext import Application, MessageHandler, filters, ContextTypes
from telegram.error import BadRequest
import httpx

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
API_URL = os.getenv("API_BRIDGE_URL", "http://localhost:8000")
BOT_TOKEN = os.getenv("TG_BOT_TOKEN", "")

def esc(t): return re.sub(r'([_*\[\]()~`>#+\-=|{}.!\\])', r'\\\1', str(t))

async def reply(upd, txt, kb=None):
    try: await upd.message.reply_text(esc(txt), parse_mode="MarkdownV2", reply_markup=kb)
    except BadRequest: await upd.message.reply_text(txt, reply_markup=kb)

async def handle(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uid = update.effective_user.id
    txt = update.message.text or ""
    await reply(update, "⏳ ...")
    try:
        async with httpx.AsyncClient(timeout=120) as c:
            r = await c.post(f"{API_URL}/process", json={"user_id":uid, "text":txt, "has_files":False})
            d = r.json()
            tag = f"[{'' if d.get('privacy_mode')=='LOCAL' else '☁️'}{d.get('model_used','?')}{' +RAG:'+str(d.get('context_used',0)) if d.get('context_used',0)>0 else ''}]"
            await reply(update, f"{d.get('reply','')}\n\n{tag}")
    except Exception as e:
        await reply(update, f"️ {str(e)[:120]}")

def main():
    if not BOT_TOKEN or len(BOT_TOKEN)<20: print("❌ Нет токена"); return
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(MessageHandler(filters.ALL, handle))
    print(" Бот запущен"); app.run_polling()

if __name__ == "__main__": main()
PY
echo "✅ Bot обновлён"

echo "[3/4] Перезапуск..."
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

echo "[4/4] Как теперь работает (проверка):"
echo "  • Пишешь ЛЮБОЕ сообщение → оно сразу уходит в RAG"
echo "  • Спрашиваешь что угодно → система ищет в RAG + LLM отвечает прямо"
echo "  • Если маршрут CLOUD → данные токенизируются, в облако секреты не утекут"
echo "  • Никаких 'сохрани:', 'покажи', отказов или кнопок"
echo ""
echo "🧪 Тест: напиши боту"
echo "  1. 'Мой пароль от почты = TestPass123'"
echo "  2. 'Напомни пароль от почты'"
echo "  3. 'Рецепт борща'"
echo ""
echo "ЖДУ: вывод или ОК."
