#!/bin/bash
set -e
cd ~/magic-brain

echo "[1/4] main.py: защита от краша API (всегда JSON)..."
cat << 'PY' > interfaces/api/main.py
import os, sys, json, logging
from pathlib import Path
from fastapi import FastAPI
from pydantic import BaseModel
from typing import Optional

sys.path.insert(0, str(Path(__file__).parent.parent.parent))
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

app = FastAPI()
user_modes = {}

class Req(BaseModel):
    user_id: int
    text: str
    force_mode: Optional[str] = None

@app.get("/health")
async def health(): return {"status":"ok"}

@app.get("/user/{uid}/mode")
async def get_mode(uid:int): return {"mode": user_modes.get(uid,"auto")}

@app.post("/user/{uid}/mode")
async def set_mode(uid:int, p:dict): user_modes[uid]=p.get("mode","auto"); return {"status":"ok"}

@app.post("/process")
async def process(r: Req):
    try:
        from agents.main.orchestrator import MagicBrain
        brain = MagicBrain()
        res = await brain.process(r.text, r.user_id, force_mode=r.force_mode)
        return res
    except Exception as e:
        logging.error(f"❌ API CRASH: {e}", exc_info=True)
        return {"reply": f"⚠️ Внутренняя ошибка: {str(e)[:120]}", "privacy_mode":"error", "model_used":"crash", "context_used":0, "tag":"[❌]"}
PY
echo "✅ main.py: всегда возвращает JSON"

echo "[2/4] bot.py: пуленепробиваемый парсинг ответа..."
cat << 'PY' > interfaces/telegram/bot.py
import os, sys, json, httpx, logging
from pathlib import Path
BASE = Path(__file__).parent.parent.parent
sys.path.insert(0, str(BASE))
for ln in (BASE/".env").read_text().splitlines():
    if "=" in ln and not ln.strip().startswith("#"): k,v=ln.split("=",1); os.environ[k.strip()]=v.strip()

from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, MessageHandler, filters, ContextTypes, CallbackQueryHandler
from telegram.error import BadRequest

API_URL = os.getenv("API_BRIDGE_URL", "http://localhost:8000")
BOT_TOKEN = os.getenv("TG_BOT_TOKEN", "")
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(message)s')

def kb(mode="auto"):
    i={"agent":"✅","chat":"🔘","rag":"🔘","web":"🔘","auto":"🔘"}; i[mode]="✅"
    return InlineKeyboardMarkup([
        [InlineKeyboardButton(f"{i['agent']} 🛠️", callback_data=json.dumps({"t":"m","m":"agent"})),
         InlineKeyboardButton(f"{i['chat']} 💬", callback_data=json.dumps({"t":"m","m":"chat"}))],
        [InlineKeyboardButton(f"{i['rag']} 🗄️", callback_data=json.dumps({"t":"m","m":"rag"})),
         InlineKeyboardButton(f"{i['web']} 🌐", callback_data=json.dumps({"t":"m","m":"web"}))]
    ])

async def reply(msg, txt, mode="auto"):
    try: await msg.reply_text(txt, reply_markup=kb(mode))
    except BadRequest: await msg.reply_text(txt[:1000], reply_markup=kb(mode))

async def handle_cb(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query; await q.answer()
    d = json.loads(q.data)
    if d.get("t")=="m":
        mode = d.get("m","auto"); ctx.user_data["mode"]=mode
        await q.answer(text=f"Режим: {mode.upper()}", show_alert=True)
        await reply(q.message, f"✅ Выбран режим: {mode}", mode)

async def handle_msg(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    uid, txt = update.effective_user.id, update.message.text or ""
    mode = ctx.user_data.get("mode","auto")
    await update.message.reply_text("⏳ ...", reply_markup=kb(mode))
    try:
        async with httpx.AsyncClient(timeout=45) as c:
            r = await c.post(f"{API_URL}/process", json={"user_id":uid,"text":txt,"force_mode":mode if mode!="auto" else None})
            # === ЗАЩИТА ОТ КРАША ПАРСИНГА ===
            try: d = r.json()
            except Exception: d = {"reply": f"⚠️ API вернул ошибку:\n{r.text[:300]}", "tag":"[❌API]"}
            await reply(update.message, f"{d.get('reply','')}\n\n{d.get('tag','')}", mode)
    except Exception as e:
        await reply(update.message, f"⚠️ Нет связи с ядром: {str(e)[:100]}", mode)

def main():
    if not BOT_TOKEN: return
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(MessageHandler(filters.TEXT, handle_msg))
    app.add_handler(CallbackQueryHandler(handle_cb))
    print("🤖 Bot started"); app.run_polling(drop_pending_updates=True)

if __name__=="__main__": main()
PY
echo "✅ bot.py: защита от не-JSON ответа"

echo "[3/4] orchestrator.py: ленивая инициализация (0 крашей при импорте)..."
cat << 'PY' > agents/main/orchestrator.py
import os, sys, uuid, re, asyncio, logging, time
from pathlib import Path
BASE_DIR = Path(__file__).parent.parent.parent
sys.path.insert(0, str(BASE_DIR))
for ln in (BASE_DIR/".env").read_text().splitlines():
    if "=" in ln and not ln.strip().startswith("#"): k,v=ln.split("=",1); os.environ[k.strip()]=v.strip()

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s', force=True)

class MagicBrain:
    def __init__(self):
        # Ленивый импорт чтобы не крашить API при старте
        try:
            from rag.router.privacy_router import PrivacyRouter
            from rag.embed.local_embedder import LocalEmbedder
            from rag.store.qdrant_client import RAGStore
            from privacy.local_llm.ollama_client import OllamaClient
            from privacy.local_llm.openrouter_client import OpenRouterClient
            from privacy.vault.token_vault import TokenVault
            from agents.brain.registry import registry
            from agents.brain.tool_router import ToolRouter
            from agents.mcp.client import mcp as mcp_direct
            
            self.router = PrivacyRouter(); self.embedder = LocalEmbedder(); self.store = RAGStore()
            self.local_llm = OllamaClient(); self.cloud_llm = OpenRouterClient(api_key=os.getenv("OPENROUTER_API_KEY"))
            self.vault = TokenVault(); self.registry = registry; self.tool_router = ToolRouter(self)
            self.mcp_direct = mcp_direct
            self._ready = True
        except Exception as e:
            logging.error(f"⚠️ Lazy init failed: {e}")
            self._ready = False

    def _tag(self, m, mdl, c): return f"[{'🛠️' if m=='tools' else '💬'}{mdl}{' +RAG:'+str(c) if c else ''}]"

    async def _agent_execute(self, query, uid):
        if not self._ready: return None
        try:
            await self.registry.wait_ready(timeout=5)
            tools = self.registry.list(query)[:5]
            if not tools: return None
            meta = [{"name":t, "desc":self.registry.skills[t].get("desc",""), "params":self.registry.skills[t].get("params",{})} for t in tools]
            dec = await self.tool_router.select_and_parse(query, meta)
            if not dec or not dec.get("tool_name"): return None
            tn, args = dec["tool_name"], dec["args"]
            logging.info(f"🎯 Agent: {tn} | {args}")
            skill = self.registry.skills.get(tn)
            res = await skill["func"](query, {}, uid, **args) if skill and callable(skill.get("func")) else await self.mcp_direct.execute(tn, args)
            return str(res) if res else f"✅ {tn} done"
        except Exception as e:
            logging.warning(f"⚠️ Agent err: {e}")
            return None

    async def _chat_fallback(self, q, uid, start):
        if time.time()-start > 25: return "⏱️ Таймаут", "timeout", 0
        try:
            pm = self.router.classify(q)
            prompt, tok = q, {}
            if pm=="CLOUD" and self.router.needs_scrubbing(q): prompt, tok = self.vault.scrub(q)
            vec = self.embedder.embed([prompt])[0]
            ctx = [(r.get("payload") or r.get("meta") or {}).get("text","") for r in self.store.search(vec, limit=3)]
            fp = f"Отвечай кратко.\nЗапрос: {prompt}"
            if pm=="LOCAL":
                resp = await asyncio.wait_for(self.local_llm.chat(model="qwen2.5:3b", prompt=fp, context=[]), timeout=10)
                return resp, "qwen2.5:3b", len(ctx)
            else:
                resp = await asyncio.wait_for(self.cloud_llm.chat(prompt=fp, context=[]), timeout=10)
                if tok: resp = self.vault.unscrub(resp, tok)
                return resp, "cloud", len(ctx)
        except asyncio.TimeoutError: return "⏱️ Таймаут", "timeout", 0
        except: return "⚠️ Ошибка LLM", "error", 0

    async def process(self, user_query, user_id, force_mode=None, **kw):
        start = time.time()
        if force_mode not in ("chat","rag","web"):
            res = await self._agent_execute(user_query, user_id)
            if res and not res.startswith("⚠️"):
                return {"reply":res, "privacy_mode":"tools", "model_used":"agent", "context_used":0, "tag":self._tag("tools","agent",0)}
        txt, mu, c = await self._chat_fallback(user_query, user_id, start)
        pm = "LOCAL" if mu=="qwen2.5:3b" else "CLOUD"
        return {"reply":txt, "privacy_mode":pm, "model_used":mu, "context_used":c, "tag":self._tag("chat",mu,c)}
PY
echo "✅ orchestrator.py: ленивая инициализация"

echo "[4/4] Перезапуск..."
pkill -9 -f uvicorn 2>/dev/null || true; pkill -9 -f "bot.py" 2>/dev/null || true; sleep 2
set -a; source ~/magic-brain/.env; set +a
cd ~/magic-brain/interfaces/api; nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
cd ~/magic-brain/interfaces/telegram; nohup python3 bot.py > /tmp/bot.log 2>&1 &
sleep 5
curl -sf http://127.0.0.1:8000/health && echo "✅ API UP" || echo "❌ API DOWN"

echo ""
echo "🎉 Исправлено:"
echo "  • API теперь ВСЕГДА возвращает валидный JSON (даже при крахе)"
echo "  • Бот больше не падает на r.json() → покажет сырую ошибку от API если что"
echo "  • Ленивая инициализация orchestrator → 0 ошибок при импорте"
echo ""
echo "🧪 Тест: Напиши боту 'привет' или 'Создай файл ~/test.txt'"
echo "Если ошибка → скинь: tail -10 /tmp/api.log"
echo "ЖДУ: результат."
