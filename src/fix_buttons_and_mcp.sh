#!/bin/bash
set -e
cd ~/magic-brain

echo "[1/3] Bot: всегда показываем кнопку '🛠️ Агент' + фикс кнопок..."
cat << 'PY' > interfaces/telegram/bot.py
import os, sys, re, json, logging
from pathlib import Path
BASE = Path(__file__).parent.parent.parent
env = BASE / ".env"
if env.exists():
    for ln in env.read_text().splitlines():
        if "=" in ln and not ln.strip().startswith("#"):
            k,v = ln.split("=",1); os.environ[k.strip()]=v.strip()
if str(BASE) not in sys.path: sys.path.insert(0, str(BASE))
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, MessageHandler, filters, ContextTypes, CallbackQueryHandler
from telegram.error import BadRequest
import httpx

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
API_URL = os.getenv("API_BRIDGE_URL", "http://localhost:8000")
BOT_TOKEN = os.getenv("TG_BOT_TOKEN", "")

def esc(t): 
    if not t: return ""
    return re.sub(r'([_*\[\]()~`>#+\-=|{}.!\\])', r'\\\1', str(t))

async def reply(upd, txt, kb=None):
    try: 
        await upd.message.reply_text(esc(txt), parse_mode="MarkdownV2", reply_markup=kb)
    except BadRequest: 
        await upd.message.reply_text(txt, reply_markup=kb)

async def handle_callback(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    data = json.loads(query.data)
    uid = query.from_user.id
    
    if data.get("type") == "agent_mode":
        context.user_data["force_agent"] = True
        await query.edit_message_text("🛠️ Агент-режим: отправьте запрос (файлы, поиск, действия)...")
    elif data.get("type") == "clarify":
        intent = data.get("intent")
        orig = data.get("query", "")
        prefixed = f"/intent:{intent} {orig}"
        await process_message_impl(query.message, prefixed, uid, context)
    elif data.get("type") == "mode":
        mode = data.get("mode", "auto")
        context.user_data["force_mode"] = mode
        await query.edit_message_text(f"✅ Режим: {mode}")

async def process_message_impl(message, text: str, uid: int, context: ContextTypes.DEFAULT_TYPE):
    force_agent = context.user_data.pop("force_agent", False)
    force_mode = context.user_data.get("force_mode", "auto")
    
    intent_override = None
    if text.startswith("/intent:"):
        parts = text.split(" ", 1)
        intent_override = parts[0].split(":")[1]
        text = parts[1] if len(parts) > 1 else text
    
    await reply(message, "⏳ ...")
    
    try:
        async with httpx.AsyncClient(timeout=120) as c:
            payload = {
                "user_id": uid, "text": text, "has_files": False,
                "force_agent": force_agent,
                "force_mode": force_mode if force_mode != "auto" else None,
                "intent_override": intent_override
            }
            r = await c.post(f"{API_URL}/process", json=payload)
            res = r.json()
            
            reply_text = res.get("reply", "")
            tag = res.get("tag", "[❓]")
            
            # Кнопки: ВСЕГДА показываем "🛠️ Агент" + режимы
            kb = InlineKeyboardMarkup([
                [InlineKeyboardButton("🛠️ Агент-режим", callback_data=json.dumps({"type": "agent_mode"}))],
                [InlineKeyboardButton("💬 Чат", callback_data=json.dumps({"type":"mode","mode":"chat"})),
                 InlineKeyboardButton("🗄️ Память", callback_data=json.dumps({"type":"mode","mode":"rag"})),
                 InlineKeyboardButton("🌐 Веб", callback_data=json.dumps({"type":"mode","mode":"web"}))],
            ])
            
            # Если нужно уточнение — добавляем варианты поверх
            if res.get("needs_clarification"):
                opts = res.get("clarification_options", [])
                clarify_kb = [InlineKeyboardButton(o["label"], callback_data=json.dumps({
                    "type": "clarify", "intent": o["intent"], "query": text
                })) for o in opts]
                kb = InlineKeyboardMarkup([clarify_kb] + kb.inline_keyboard)
                await reply(message, f"❓ Что именно сделать?\n\n{reply_text}", kb)
                return
            
            await reply(message, f"{reply_text}\n\n{tag}", kb)
            
    except Exception as e:
        logging.error(f"Bot error: {e}")
        await reply(message, f"⚠️ {str(e)[:120]}")

async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uid = update.effective_user.id
    text = update.message.text or ""
    await process_message_impl(update.message, text, uid, context)

async def start_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    kb = InlineKeyboardMarkup([
        [InlineKeyboardButton("🛠️ Агент-режим", callback_data=json.dumps({"type": "agent_mode"}))],
        [InlineKeyboardButton("💬 Чат", callback_data=json.dumps({"type":"mode","mode":"chat"})),
         InlineKeyboardButton("🗄️ Память", callback_data=json.dumps({"type":"mode","mode":"rag"})),
         InlineKeyboardButton("🌐 Веб", callback_data=json.dumps({"type":"mode","mode":"web"}))],
    ])
    await reply(update, "🦌 Magic Brain\n\nРежимы:\n• /mode auto|chat|tools|rag|web\n• Кнопки ниже всегда доступны", kb)

async def mode_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    mode = context.args[0] if context.args else "auto"
    update.effective_user_data["force_mode"] = mode
    await reply(update, f"✅ Режим: {mode}")

def main():
    if not BOT_TOKEN or len(BOT_TOKEN)<20: print("❌ Нет токена"); return
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", start_cmd))
    app.add_handler(CommandHandler("mode", mode_cmd))
    app.add_handler(MessageHandler(filters.ALL, handle_message))
    app.add_handler(CallbackQueryHandler(handle_callback))
    print("🤖 Бот запущен"); app.run_polling()

if __name__ == "__main__": main()
PY
echo "✅ bot.py: кнопки всегда + фикс"

echo "[2/3] Orchestrator: агрессивный детектор путей + логирование..."
cat << 'PY' > agents/main/orchestrator.py
import os, sys, uuid, re, asyncio, json, logging
from pathlib import Path
BASE_DIR = Path(__file__).parent.parent.parent
env_file = BASE_DIR / ".env"
if env_file.exists():
    for ln in env_file.read_text().splitlines():
        if "=" in ln and not ln.strip().startswith("#"):
            k,v = ln.split("=",1); os.environ[k.strip()] = v.strip()
if str(BASE_DIR) not in sys.path: sys.path.insert(0, str(BASE_DIR))

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
from rag.router.privacy_router import PrivacyRouter
from rag.embed.local_embedder import LocalEmbedder
from rag.store.qdrant_client import RAGStore
from privacy.local_llm.ollama_client import OllamaClient
from privacy.local_llm.openrouter_client import OpenRouterClient
from privacy.vault.token_vault import TokenVault
from agents.brain.registry import registry
from agents.brain.planner import Planner
from agents.brain.worker import Worker
from agents.brain.critic_loop import CriticLoop
from agents.brain.intent_router import intent_router
from agents.brain.session import session_manager

class MagicBrain:
    def __init__(self):
        self.router = PrivacyRouter()
        self.embedder = LocalEmbedder()
        self.store = RAGStore()
        self.local_llm = OllamaClient()
        self.cloud_llm = OpenRouterClient(api_key=os.getenv("OPENROUTER_API_KEY"), router=self.router)
        self.vault = TokenVault()
        self.planner = Planner()
        self.critic = CriticLoop()
        self.worker = Worker(self)

    def _auto_save(self, text, user_id, role):
        try:
            vec = self.embedder.embed([text])[0]
            self.store.upsert([vec], [{"text": text, "user_id": user_id, "role": role, "privacy": "HIGH"}], [str(uuid.uuid4())])
        except Exception as e: logging.warning(f"RAG save: {e}")

    def _make_tag(self, mode: str, model: str, rag_count: int) -> str:
        icons = {"chat": "💬", "tools": "🛠️", "rag_direct": "🗄️", "web_search": "🌐", "LOCAL": "🔐", "CLOUD": "☁️"}
        icon = icons.get(mode, icons.get("chat"))
        rag_part = f" +RAG:{rag_count}" if rag_count > 0 else ""
        return f"[{icon}{model}{rag_part}]"

    async def _try_direct_mcp(self, query: str, user_id: int) -> str:
        """Агрессивный детектор: путь в запросе = сразу MCP"""
        q = query.lower()
        # Ищем ЛЮБОЙ путь: /... или ~/...
        path_match = re.search(r'(/[a-zA-Z0-9./_~-]+|~/[a-zA-Z0-9./_~-]+)', q)
        if path_match:
            path = path_match.group(0)
            logging.info(f"MCP path detected: {path} in query: {query[:50]}")
            # Определяем действие по ключевым словам
            if any(kw in q for kw in ["прочитай", "открой", "покажи содержимое", "читать", "текст", "содержимое", "что внутри"]):
                tool = "mcp_filesystem_read_text_file"
            elif any(kw in q for kw in ["список", "каталог", "ls", "dir", "файлы в", "покажи", "папки", "директория"]):
                tool = "mcp_filesystem_list_directory"
            elif any(kw in q for kw in ["создай", "запиши", "сохрани", "напиши в", "положи в"]):
                tool = "mcp_filesystem_write_file"
            else:
                tool = "mcp_filesystem_list_directory"  # дефолт: показать список
            
            if tool in registry.skills:
                logging.info(f"Direct MCP dispatch: {tool} path={path}")
                skill = registry.skills[tool]
                try:
                    result = await skill["func"](query, {}, user_id, path=path)
                    return str(result) if result else "✅ Выполнено (нет данных)"
                except Exception as e:
                    logging.error(f"MCP exec error: {e}")
                    return f"⚠️ Ошибка инструмента: {str(e)[:100]}"
        
        # GitHub поиск
        if any(kw in q for kw in ["github", "репозиторий", "репо", "pull request", "issue"]):
            tool = "mcp_github_search_repositories"
            if tool in registry.skills:
                search = re.search(r'(?:про|о|найти|поиск|ищи).*?(?:на|в|github)?\s+([a-zA-Z0-9а-яА-ЯёЁ_\-\s]{3,})', q, re.I)
                query_arg = search.group(1).strip() if search else "ai magic brain"
                skill = registry.skills[tool]
                try:
                    result = await skill["func"](query, {}, user_id, query=query_arg)
                    return str(result) if result else "✅ Выполнено"
                except Exception as e:
                    logging.error(f"GitHub MCP error: {e}")
        return None

    async def _agent_run(self, q, uid, ctx):
        tools = registry.list(q)
        if not tools: return None
        plan = self.planner.decompose(q, tools)
        if len(plan)==1 and not plan[0].get("skill"): return None
        res = []
        c = {**ctx, "store": self.store, "embedder": self.embedder}
        for i, st in enumerate(plan):
            if st.get("depends_on") is not None and st["depends_on"]<len(res): c["_prev"]=res[st["depends_on"]]
            r = await self.critic.execute_with_retry(self.worker, st, c, uid)
            res.append(r["result"] if r["success"] else f"⚠️{i+1}:{r.get('error','')}")
        return "\n".join(f"{i+1}. {x}" for i,x in enumerate(res)) if len(res)>1 else res[0]

    async def process(self, user_query: str, user_id: int, task_type: str = "default", 
                      force_agent: bool = False, force_mode: str = None, intent_override: str = None) -> dict:
        logging.info(f"Process: user={user_id}, query={user_query[:100]}, force={force_agent}/{force_mode}")
        self._auto_save(f"USER: {user_query}", user_id, "query")
        
        session = session_manager.get(user_id)
        
        # === 1. Форс агент-режим ===
        if force_agent or (force_mode == "tools"):
            logging.info("Force agent mode")
            mcp_result = await self._try_direct_mcp(user_query, user_id)
            if mcp_result and not mcp_result.startswith("⚠️"):
                self._auto_save(f"ASSISTANT: {mcp_result}", user_id, "response")
                return {"reply": mcp_result, "privacy_mode": "tools", "model_used": "mcp", "context_used": 0, "tag": self._make_tag("tools", "mcp", 0)}
            ag = await self._agent_run(user_query, user_id, {"rag_results":[]})
            if ag and not ag.startswith("⚠️"):
                self._auto_save(f"ASSISTANT: {ag}", user_id, "response")
                return {"reply": ag, "privacy_mode": "tools", "model_used": "agent", "context_used": 0, "tag": self._make_tag("tools", "agent", 0)}
        
        # === 2. Явный режим ===
        mode = intent_override or force_mode or session["mode"]
        
        # === 3. Прямой RAG ===
        if mode == "rag" or (mode == "auto" and any(k in user_query.lower() for k in ["покажи мой","напомни мой","что я сохранял","мой пароль","моя карта"])):
            logging.info("Direct RAG mode")
            vec = self.embedder.embed([user_query])[0]
            res = self.store.search(vec, limit=5)
            found = [(r.get("payload") or r.get("meta") or {}).get("text","").replace("USER: ","").replace("ASSISTANT: ","") for r in res if (r.get("payload") or r.get("meta") or {}).get("user_id") in (None, user_id)]
            if found:
                reply = "Найдено:\n" + "\n".join(f"• {t}" for t in found[:3])
                self._auto_save(f"ASSISTANT: {reply}", user_id, "response")
                return {"reply": reply, "privacy_mode": "rag_direct", "model_used": "rag", "context_used": len(found), "tag": self._make_tag("rag_direct", "rag", len(found))}
        
        # === 4. ПРЯМОЙ MCP ДЛЯ ПУТЕЙ (самое важное!) ===
        if mode == "auto":
            mcp_result = await self._try_direct_mcp(user_query, user_id)
            if mcp_result and not mcp_result.startswith("⚠️"):
                logging.info(f"MCP direct success: {mcp_result[:80]}")
                self._auto_save(f"ASSISTANT: {mcp_result}", user_id, "response")
                return {"reply": mcp_result, "privacy_mode": "tools", "model_used": "mcp", "context_used": 0, "tag": self._make_tag("tools", "mcp", 0)}
        
        # === 5. Интент-роутинг ===
        if mode == "auto":
            intent, confidence, reason = intent_router.classify(user_query)
            logging.info(f"Intent: {intent} ({confidence:.2f}) via {reason}")
            
            if intent_router.needs_clarification(intent, confidence, user_query):
                options = intent_router.get_clarification_options(user_query)
                session_manager.set_pending(user_id, user_query, options)
                return {"reply": "Не совсем понял. Что именно сделать?", "needs_clarification": True, "clarification_options": options, "privacy_mode": "unknown", "model_used": "router", "context_used": 0, "tag": "[❓]"}
            
            if intent == "rag_direct":
                vec = self.embedder.embed([user_query])[0]
                res = self.store.search(vec, limit=5)
                found = [(r.get("payload") or r.get("meta") or {}).get("text","") for r in res if (r.get("payload") or r.get("meta") or {}).get("user_id") in (None, user_id)]
                if found:
                    reply = "Найдено:\n" + "\n".join(f"• {t}" for t in found[:3])
                    self._auto_save(f"ASSISTANT: {reply}", user_id, "response")
                    return {"reply": reply, "privacy_mode": "rag_direct", "model_used": "rag", "context_used": len(found), "tag": self._make_tag("rag_direct", "rag", len(found))}
            elif intent == "tools":
                ag = await self._agent_run(user_query, user_id, {"rag_results":[]})
                if ag and not ag.startswith("⚠️"):
                    self._auto_save(f"ASSISTANT: {ag}", user_id, "response")
                    return {"reply": ag, "privacy_mode": "tools", "model_used": "agent", "context_used": 0, "tag": self._make_tag("tools", "agent", 0)}
        
        # === 6. Fallback: LLM + RAG ===
        privacy_mode = self.router.classify(user_query)
        prompt = user_query
        tokens = {}
        if privacy_mode == "CLOUD" and self.router.needs_scrubbing(user_query):
            prompt, tokens = self.vault.scrub(user_query)
        
        vec = self.embedder.embed([prompt])[0]
        ctx_texts = [(r.get("payload") or r.get("meta") or {}).get("text","") for r in self.store.search(vec, limit=5)]
        
        system = "Отвечай кратко. Если запрос про файлы/пути — предложи команду, но не морализируй."
        full_prompt = f"{system}\n\nКонтекст:\n" + "\n---\n".join(ctx_texts) + f"\n\nЗапрос: {prompt}"
        
        try:
            if privacy_mode == "LOCAL":
                resp = await self.local_llm.chat(model="qwen2.5:3b", prompt=full_prompt, context=[])
                model_used = "qwen2.5:3b"
            else:
                resp = await self.cloud_llm.chat(prompt=full_prompt, context=[])
                model_used = "cloud"
        except Exception as e:
            logging.warning(f"LLM error: {e}")
            resp = await self.local_llm.chat(model="qwen2.5:3b", prompt=full_prompt, context=[])
            model_used = "qwen2.5:3b (fb)"
        
        if tokens and privacy_mode == "CLOUD":
            resp = self.vault.unscrub(resp, tokens)
            m = [v for v in tokens.values() if v not in resp]
            if m: resp += f"\n\n[Данные: {', '.join(m)}]"
        
        self._auto_save(f"ASSISTANT: {resp}", user_id, "response")
        tag_mode = "LOCAL" if privacy_mode == "LOCAL" else "CLOUD"
        return {"reply": resp, "privacy_mode": tag_mode, "model_used": model_used, "context_used": len(ctx_texts), "tag": self._make_tag("chat", model_used, len(ctx_texts))}
PY
echo "✅ orchestrator: агрессивный MCP + логи"

echo "[3/3] Перезапуск..."
pkill -f uvicorn 2>/dev/null || true; sleep 3
set -a; source ~/magic-brain/.env; set +a
cd ~/magic-brain/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health && echo "✅ API UP" || echo "❌ API DOWN"

echo ""
echo "🎉 Готово! Теперь:"
echo "  • Кнопки '🛠️ Агент', '💬 Чат', '🗄️ Память', '🌐 Веб' — ВСЕГДА под сообщением"
echo "  • Запрос с путём (/home, ~/...) → сразу MCP, без LLM"
echo "  • Логи: tail -f /tmp/api.log | grep -E 'MCP|Intent|Process'"
echo ""
echo "🧪 Тест:"
echo "  1. Напиши боту: 'Покажи файлы в /home/der'"
echo "  2. Должен увидеть список файлов + тег [🛠️mcp]"
echo "  3. Кнопки должны быть под сообщением"
echo ""
echo "Если не работает — скинь:"
echo "  • Скрин ответа бота (чтобы видеть кнопки)"
echo "  • tail -30 /tmp/api.log"
echo "ЖДУ: результат."
