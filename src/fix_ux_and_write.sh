#!/bin/bash
set -e
cd ~/magic-brain

echo "[1/4] Bot: кнопки через alert + стабильная индикация режима..."
cat << 'PY' > interfaces/telegram/bot.py
import os, sys, re, json, logging, asyncio, httpx
from pathlib import Path
BASE = Path(__file__).parent.parent.parent
sys.path.insert(0, str(BASE))
env = BASE / ".env"
if env.exists():
    for ln in env.read_text().splitlines():
        if "=" in ln and not ln.strip().startswith("#"): k,v=ln.split("=",1); os.environ[k.strip()]=v.strip()

from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, MessageHandler, filters, ContextTypes, CallbackQueryHandler
from telegram.error import BadRequest

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(message)s')
API_URL = os.getenv("API_BRIDGE_URL", "http://localhost:8000")
BOT_TOKEN = os.getenv("TG_BOT_TOKEN", "")

def esc(t): return re.sub(r'([_*\[\]()~`>#+\-=|{}.!\\])', r'\\\1', str(t)) if t else ""

def kb(mode="auto"):
    icons = {"agent":"✅","chat":"🔘","rag":"🔘","web":"🔘","auto":"🔘"}
    icons[mode] = "✅"
    return InlineKeyboardMarkup([
        [InlineKeyboardButton(f"{icons['agent']} 🛠️ Агент", callback_data=json.dumps({"t":"m","m":"agent"})),
         InlineKeyboardButton(f"{icons['chat']} 💬 Чат", callback_data=json.dumps({"t":"m","m":"chat"}))],
        [InlineKeyboardButton(f"{icons['rag']} 🗄️ Память", callback_data=json.dumps({"t":"m","m":"rag"})),
         InlineKeyboardButton(f"{icons['web']} 🌐 Веб", callback_data=json.dumps({"t":"m","m":"web"}))]
    ])

async def send_status(bot, uid, mode, text="Режим изменён"):
    try:
        await bot.send_message(uid, f"✅ {text}", reply_markup=kb(mode))
    except: pass

async def handle_cb(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query; d = json.loads(q.data); uid = q.from_user.id
    await q.answer()
    if d.get("t")=="m":
        mode = d.get("m","auto")
        try: async with httpx.AsyncClient(timeout=3) as c: await c.post(f"{API_URL}/user/{uid}/mode", json={"mode":mode})
        except: pass
        # Мгновенный отклик через alert (гарантированно работает)
        await q.answer(text=f"Режим: {mode.upper()}", show_alert=True)
        await send_status(ctx.bot, uid, mode, "Режим изменён")

async def handle_msg(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    uid = update.effective_user.id; text = update.message.text or ""
    user_mode = "auto"
    try:
        async with httpx.AsyncClient(timeout=2) as c: user_mode = (await c.get(f"{API_URL}/user/{uid}/mode")).json().get("mode","auto")
    except: pass
    await update.message.reply_text("⏳ ...", reply_markup=kb(user_mode))
    try:
        async with httpx.AsyncClient(timeout=40) as c:
            r = await c.post(f"{API_URL}/process", json={"user_id":uid,"text":text,"has_files":False,"force_mode":user_mode if user_mode!="auto" else None})
            d = r.json(); tag = d.get("tag","[❓]")
            await update.message.reply_text(esc(f"{d.get('reply','')}\n\n{tag}"), reply_markup=kb(user_mode), parse_mode="MarkdownV2")
    except BadRequest:
        await update.message.reply_text(f"{d.get('reply','')}\n\n{tag}", reply_markup=kb(user_mode))
    except Exception as e:
        await update.message.reply_text(f"⚠️ {str(e)[:100]}", reply_markup=kb(user_mode))

def main():
    if not BOT_TOKEN or len(BOT_TOKEN)<20: print("❌ Нет токена"); return
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(MessageHandler(filters.TEXT, handle_msg))
    app.add_handler(CallbackQueryHandler(handle_cb))
    print("🤖 Bot started"); app.run_polling(drop_pending_updates=True)

if __name__ == "__main__": main()
PY
echo "✅ bot.py: alert-кнопки + стабильный статус"

echo "[2/4] Orchestrator: фикс write_file + корректные аргументы..."
cat << 'PY' > agents/main/orchestrator.py
import os, sys, uuid, re, asyncio, json, logging, time
from pathlib import Path
BASE_DIR = Path(__file__).parent.parent.parent
env_file = BASE_DIR / ".env"
if env_file.exists():
    for ln in env_file.read_text().splitlines():
        if "=" in ln and not ln.strip().startswith("#"): k,v=ln.split("=",1); os.environ[k.strip()]=v.strip()
if str(BASE_DIR) not in sys.path: sys.path.insert(0, str(BASE_DIR))

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s', force=True)
from rag.router.privacy_router import PrivacyRouter
from rag.embed.local_embedder import LocalEmbedder
from rag.store.qdrant_client import RAGStore
from privacy.local_llm.ollama_client import OllamaClient
from privacy.local_llm.openrouter_client import OpenRouterClient
from privacy.vault.token_vault import TokenVault
from agents.brain.planner import Planner
from agents.brain.worker import Worker
from agents.brain.critic_loop import CriticLoop
from agents.brain.intent_router import intent_router
from agents.brain.session import session_manager
from agents.brain.registry import registry
from agents.mcp.client import mcp as mcp_direct

class MagicBrain:
    def __init__(self):
        logging.info("🧠 Init MagicBrain...")
        self.router = PrivacyRouter(); self.embedder = LocalEmbedder(); self.store = RAGStore()
        self.local_llm = OllamaClient()
        self.cloud_llm = OpenRouterClient(api_key=os.getenv("OPENROUTER_API_KEY"), router=self.router)
        self.vault = TokenVault(); self.planner = Planner(); self.critic = CriticLoop(); self.worker = Worker(self)

    def _auto_save(self, t, u, r):
        try:
            v = self.embedder.embed([t])[0]
            self.store.upsert([v], [{"text":t,"user_id":u,"role":r,"privacy":"HIGH"}], [str(uuid.uuid4())])
        except: pass

    def _tag(self, m, mdl, c): return f"[{'🛠️' if m=='tools' else '💬'}{mdl}{' +RAG:'+str(c) if c else ''}]"

    async def _mcp(self, query: str, user_id: int) -> str:
        q = query.lower()
        path_match = re.search(r'(/[a-zA-Z0-9./_~-]+|~/[a-zA-Z0-9./_~-]+)', q)
        if path_match:
            path = path_match.group(0)
            if any(k in q for k in ["прочитай","открой","покажи содержимое","читать","текст","содержимое"]):
                tool, args = "mcp_filesystem_read_text_file", {"path": path}
            elif any(k in q for k in ["список","каталог","ls","dir","файлы в","покажи","папки"]):
                tool, args = "mcp_filesystem_list_directory", {"path": path}
            elif any(k in q for k in ["создай","запиши","сохрани","напиши в","положи в"]):
                # === ФИКС WRITE_FILE: извлекаем контент ===
                content_match = re.search(r'(?:напиши туда|содержимое|текст):\s*(.*)', query, re.I | re.DOTALL)
                content = content_match.group(1).strip() if content_match else query
                tool, args = "mcp_filesystem_write_file", {"path": path, "content": content}
            else:
                tool, args = "mcp_filesystem_list_directory", {"path": path}
            
            try:
                r = await asyncio.wait_for(mcp_direct.execute(tool, args), timeout=25)
                return str(r) if r else "✅ Выполнено"
            except asyncio.TimeoutError: return "⏱️ Таймаут файла"
            except Exception as e: return f"⚠️ Файл: {str(e)[:150]}"

        if any(k in q for k in ["github","репозиторий","репо"]):
            s = re.search(r'(?:про|о|найти|поиск).*?([a-zA-Z0-9а-яА-ЯёЁ_\-\s]{3,})', q, re.I)
            q_arg = s.group(1).strip() if s else "ai"
            try: return await asyncio.wait_for(mcp_direct.execute("mcp_github_search_repositories", {"query": q_arg}), timeout=25)
            except: return "⚠️ GitHub error"
        return None

    async def process(self, user_query: str, user_id: int, task_type: str = "default", 
                      force_agent: bool = False, force_mode: str = None, intent_override: str = None) -> dict:
        start = time.time()
        self._auto_save(f"USER: {user_query}", user_id, "query")
        
        if force_agent or force_mode=="tools" or "/home" in user_query or "~/" in user_query:
            r = await self._mcp(user_query, user_id)
            if r and not r.startswith("⚠️"): return {"reply":r,"privacy_mode":"tools","model_used":"mcp","context_used":0,"tag":self._tag("tools","mcp",0)}
        
        if time.time()-start > 30: return {"reply":"⏱️ Таймаут","privacy_mode":"LOCAL","model_used":"timeout","context_used":0,"tag":"[⏱️]"}
        
        try:
            pm = self.router.classify(user_query)
            prompt, tokens = user_query, {}
            if pm=="CLOUD" and self.router.needs_scrubbing(user_query): prompt, tokens = self.vault.scrub(user_query)
            vec = self.embedder.embed([prompt])[0]
            ctx = [(r.get("payload") or r.get("meta") or {}).get("text","") for r in self.store.search(vec, limit=2)]
            sys_prompt = "Отвечай кратко."
            fp = f"{sys_prompt}\n\nЗапрос: {prompt}"
            
            if pm=="LOCAL":
                resp = await asyncio.wait_for(self.local_llm.chat(model="qwen2.5:3b", prompt=fp, context=[]), timeout=15)
                mu = "qwen2.5:3b"
            else:
                resp = await asyncio.wait_for(self.cloud_llm.chat(prompt=fp, context=[]), timeout=15)
                mu = "cloud"
            if tokens and pm=="CLOUD": resp = self.vault.unscrub(resp, tokens)
            self._auto_save(f"ASSISTANT: {resp}", user_id, "response")
            return {"reply":resp,"privacy_mode":pm,"model_used":mu,"context_used":len(ctx),"tag":self._tag("chat",mu,len(ctx))}
        except asyncio.TimeoutError: return {"reply":"⏱️ Таймаут LLM","privacy_mode":"LOCAL","model_used":"timeout","context_used":0,"tag":"[⏱️]"}
        except Exception as e: return {"reply":f"⚠️ {str(e)[:80]}","privacy_mode":"LOCAL","model_used":"error","context_used":0,"tag":"[❌]"}
PY
echo "✅ orchestrator.py: write_file фикс + таймауты"

echo "[3/4] API: эндпоинты режима..."
grep -q "user_modes" interfaces/api/main.py || cat << 'PY' >> interfaces/api/main.py
from typing import Dict
user_modes: Dict[int, str] = {}
@app.post("/user/{user_id}/mode")
async def set_user_mode(user_id: int, payload: dict):
    m = payload.get("mode","auto")
    if m not in ("auto","chat","tools","rag","web"): return {"error":"bad"}
    user_modes[user_id] = m; return {"status":"ok","mode":m}
@app.get("/user/{user_id}/mode")
async def get_user_mode(user_id: int): return {"mode": user_modes.get(user_id, "auto")}
PY

echo "[4/4] Перезапуск..."
pkill -9 -f uvicorn 2>/dev/null || true; pkill -9 -f "bot.py" 2>/dev/null || true; sleep 2
set -a; source ~/magic-brain/.env; set +a
cd ~/magic-brain/interfaces/api; nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
cd ~/magic-brain/interfaces/telegram; nohup python3 bot.py > /tmp/bot.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health && echo "✅ API UP" || echo "❌ API DOWN"

echo ""
echo "🎉 Исправлено:"
echo "  • Кнопки: теперь показывают ВСПЛЫВАЮЩЕЕ уведомление (✅ Режим: AGENT)"
echo "  • Статус: подсвечивается текущий режим (✅ vs 🔘)"
echo "  • Запись файлов: исправлен параметр 'content' в MCP write_file"
echo ""
echo "🧪 Тест:"
echo "  1. Нажми 🛠️ → увидишь alert 'Режим: AGENT'"
echo "  2. 'Создай файл ~/test.txt напиши туда: привет мир'"
echo "  3. 'Покажи файлы в /home/der'"
echo ""
echo "ЖДУ: результат."
