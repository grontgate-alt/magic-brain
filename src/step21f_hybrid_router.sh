#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain
cd "$BASE"

echo "[1/6] Intent Router: детекция + уверенность + режимы..."
cat << 'PY' > agents/brain/intent_router.py
import re
from typing import Literal, Tuple

Intent = Literal["chat", "tools", "rag_direct", "web_search", "unknown"]

class IntentRouter:
    """Определяет интент запроса с оценкой уверенности"""
    
    # Паттерны с весами уверенности (0.0-1.0)
    PATTERNS = {
        "tools": [
            (r'(/[\w./~-]+|~/[\w./~-]+)', 0.95),  # путь → файлы
            (r'покажи.*файл|прочитай.*файл|открой.*файл|сохрани.*файл', 0.9),
            (r'список.*файлов|каталог|ls|dir|файлы в', 0.85),
            (r'github.*репозиторий|поиск.*репозиторий|repo|pull request', 0.9),
            (r'посчитай|вычисли|калькулятор|\d+[\s]*[\*\+\-/]', 0.8),
            (r'веб|поиск.*интернет|найди.*в интернете|гугл', 0.85),
        ],
        "rag_direct": [
            (r'покажи.*мой|напомни.*мой|что я сохранял|мой пароль|моя карта|мой телефон', 0.95),
            (r'достань.*из памяти|верни.*из хранилища|найди.*в памяти', 0.9),
        ],
        "web_search": [
            (r'найди.*в интернете|поиск.*веб|гугл.*про|новости.*про|статья.*про', 0.85),
        ],
        "chat": [
            (r'привет|как дела|что нового|расскажи|объясни|помоги', 0.7),
        ],
    }
    
    def classify(self, query: str) -> Tuple[Intent, float, str]:
        """
        Возвращает: (интент, уверенность, причина)
        """
        q = query.lower().strip()
        scores: dict[str, float] = {}
        reasons: dict[str, str] = {}
        
        for intent, patterns in self.PATTERNS.items():
            for pattern, weight in patterns:
                if re.search(pattern, q, re.I):
                    if intent not in scores or weight > scores[intent]:
                        scores[intent] = weight
                        reasons[intent] = pattern
        
        if not scores:
            return "chat", 0.5, "default"  # дефолт: чат
        
        # Выбираем лучший
        best_intent = max(scores, key=scores.get)
        confidence = scores[best_intent]
        reason = reasons[best_intent]
        
        # Эвристика: если есть "мой" + "пароль/память" → точно rag_direct
        if "мой" in q and any(k in q for k in ["пароль", "память", "сохранил", "запомнил"]):
            return "rag_direct", 0.99, "personal_data_keyword"
        
        return best_intent, confidence, reason
    
    def needs_clarification(self, intent: Intent, confidence: float, query: str) -> bool:
        """Нужно ли уточнить у пользователя?"""
        if confidence >= 0.9:
            return False
        if intent == "chat":
            return False  # чат всегда безопасен
        if confidence < 0.7:
            return True
        # Пограничные случаи
        if intent == "tools" and "покажи" in query.lower():
            # "покажи" может быть и про файлы, и про память
            return confidence < 0.85
        return False
    
    def get_clarification_options(self, query: str) -> list[dict]:
        """Возвращает варианты для уточнения"""
        return [
            {"label": "🗄️ Найти в памяти", "intent": "rag_direct", "payload": query},
            {"label": "🛠️ Выполнить действие", "intent": "tools", "payload": query},
            {"label": "💬 Просто ответить", "intent": "chat", "payload": query},
        ]

intent_router = IntentRouter()
PY
echo "✅ intent_router.py"

echo "[2/6] Session Manager: хранение режима пользователя..."
cat << 'PY' > agents/brain/session.py
from typing import Optional, Dict
from collections import defaultdict
import time

class SessionManager:
    """Хранит предпочтения режима для каждого пользователя"""
    def __init__(self, ttl_seconds: int = 3600):
        self.sessions: Dict[int, dict] = defaultdict(lambda: {
            "mode": "auto",  # auto|chat|tools|rag_direct|web_search
            "last_activity": time.time(),
            "pending_clarification": None,  # если ждём уточнения
        })
        self.ttl = ttl_seconds
    
    def get(self, user_id: int) -> dict:
        session = self.sessions[user_id]
        # TTL cleanup
        if time.time() - session["last_activity"] > self.ttl:
            session["mode"] = "auto"
            session["pending_clarification"] = None
        session["last_activity"] = time.time()
        return session
    
    def set_mode(self, user_id: int, mode: str):
        self.sessions[user_id]["mode"] = mode
        self.sessions[user_id]["pending_clarification"] = None
    
    def set_pending(self, user_id: int, query: str, options: list):
        self.sessions[user_id]["pending_clarification"] = {
            "query": query, "options": options, "created": time.time()
        }
    
    def clear_pending(self, user_id: int):
        self.sessions[user_id]["pending_clarification"] = None
    
    def get_pending(self, user_id: int) -> Optional[dict]:
        pending = self.sessions[user_id]["pending_clarification"]
        if pending and time.time() - pending["created"] > 300:  # 5 мин таймаут
            self.clear_pending(user_id)
            return None
        return pending

session_manager = SessionManager()
PY
echo "✅ session.py"

echo "[3/6] Bot: inline-кнопка '🛠️ Агент-режим' + обработка уточнений..."
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

def esc(t): return re.sub(r'([_*\[\]()~`>#+\-=|{}.!\\])', r'\\\1', str(t))

async def reply(upd, txt, kb=None):
    try: await upd.message.reply_text(esc(txt), parse_mode="MarkdownV2", reply_markup=kb)
    except BadRequest: await upd.message.reply_text(txt, reply_markup=kb)

async def handle_callback(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Обработка inline-кнопок"""
    query = update.callback_query
    await query.answer()
    data = json.loads(query.data)
    uid = query.from_user.id
    
    if data.get("type") == "agent_mode":
        # Принудительный агент-режим
        await query.edit_message_text("🛠️ Агент-режим активирован. Отправьте запрос...")
        context.user_data["force_agent"] = True
    elif data.get("type") == "clarify":
        # Пользователь выбрал вариант уточнения
        intent = data.get("intent")
        orig_query = data.get("query")
        # Отправляем запрос с префиксом для бэкенда
        prefixed = f"/intent:{intent} {orig_query}"
        await process_message_impl(query.message, prefixed, uid, context)
    elif data.get("type") == "mode":
        # Смена режима
        mode = data.get("mode")
        await query.edit_message_text(f"✅ Режим: {mode}")
        context.user_data["force_mode"] = mode

async def process_message_impl(message, text: str, uid: int, context: ContextTypes.DEFAULT_TYPE):
    """Общая логика обработки сообщения"""
    # Проверяем форс-режимы
    force_agent = context.user_data.pop("force_agent", False)
    force_mode = context.user_data.get("force_mode", "auto")
    
    # Префикс /intent: из уточнения
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
            
            # Если нужно уточнение — показываем кнопки
            if res.get("needs_clarification"):
                opts = res.get("clarification_options", [])
                kb = InlineKeyboardMarkup([
                    [InlineKeyboardButton(o["label"], callback_data=json.dumps({
                        "type": "clarify", "intent": o["intent"], "query": text
                    }))] for o in opts
                ])
                await reply(message, f"❓ Не совсем понял. Что хотите сделать?\n\n{reply_text}", kb)
                return
            
            # Кнопка "🛠️ Агент-режим" для повторного запуска с инструментами
            kb = None
            if res.get("privacy_mode") != "tools" and res.get("context_used", 0) == 0:
                kb = InlineKeyboardMarkup([[
                    InlineKeyboardButton("🛠️ Повторить в агент-режиме", callback_data=json.dumps({"type": "agent_mode"}))
                ]])
            
            await reply(message, f"{reply_text}\n\n{tag}", kb)
            
    except Exception as e:
        await reply(message, f"⚠️ {str(e)[:120]}")

async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uid = update.effective_user.id
    text = update.message.text or ""
    await process_message_impl(update.message, text, uid, context)

async def start_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE):
    kb = InlineKeyboardMarkup([
        [InlineKeyboardButton("🛠️ Агент-режим", callback_data=json.dumps({"type": "agent_mode"}))],
        [InlineKeyboardButton("💬 Чат", callback_data=json.dumps({"type": "mode", "mode": "chat"})),
         InlineKeyboardButton("🗄️ Память", callback_data=json.dumps({"type": "mode", "mode": "rag_direct"})),
         InlineKeyboardButton("🌐 Веб", callback_data=json.dumps({"type": "mode", "mode": "web_search"}))],
    ])
    await reply(update, "🦌 Magic Brain\n\nРежимы:\n• /mode auto|chat|tools|rag|web\n• Кнопки ниже\n• Пиши как есть — система поймёт", kb)

def main():
    if not BOT_TOKEN or len(BOT_TOKEN)<20: print("❌ Нет токена"); return
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", start_cmd))
    app.add_handler(CommandHandler("mode", lambda u,c: reply(u, f"✅ Режим: {c.args[0] if c.args else 'auto'}") or setattr(c.user_data, "force_mode", c.args[0] if c.args else "auto") if c.args else None))
    app.add_handler(MessageHandler(filters.ALL, handle_message))
    app.add_handler(CallbackQueryHandler(handle_callback))
    print("🤖 Бот запущен"); app.run_polling()

if __name__ == "__main__": main()
PY
echo "✅ bot.py: кнопки + уточнения"

echo "[4/6] Orchestrator: гибридный роутинг + теги..."
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
        q = query.lower()
        import re
        path_match = re.search(r'(/[\w./~-]+|~/[\w./~-]+)', q)
        if path_match:
            path = path_match.group(0)
            if any(kw in q for kw in ["прочитай", "открой", "покажи содержимое", "читать", "текст"]):
                tool = "mcp_filesystem_read_text_file"
            elif any(kw in q for kw in ["список", "каталог", "ls", "dir", "файлы в", "покажи"]):
                tool = "mcp_filesystem_list_directory"
            elif any(kw in q for kw in ["создай", "запиши", "сохрани", "напиши в"]):
                tool = "mcp_filesystem_write_file"
            else:
                tool = "mcp_filesystem_list_directory"
            if tool in registry.skills:
                logging.info(f"Direct MCP: {tool} path={path}")
                skill = registry.skills[tool]
                result = await skill["func"](query, {}, user_id, path=path)
                return str(result) if result else "✅ Выполнено"
        if "github" in q or "репозиторий" in q or "repo" in q:
            tool = "mcp_github_search_repositories"
            if tool in registry.skills:
                search = re.search(r'(?:про|о|найти|поиск).*?(?:на|в|github)?\s+([^\s,;.!"]{3,})', q, re.I)
                query_arg = search.group(1) if search else "ai magic brain"
                skill = registry.skills[tool]
                result = await skill["func"](query, {}, user_id, query=query_arg)
                return str(result) if result else "✅ Выполнено"
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
        logging.info(f"Process: user={user_id}, query={user_query[:100]}, force_agent={force_agent}, force_mode={force_mode}")
        self._auto_save(f"USER: {user_query}", user_id, "query")
        
        session = session_manager.get(user_id)
        
        # === 1. Принудительный агент-режим ===
        if force_agent or (force_mode == "tools"):
            mcp_result = await self._try_direct_mcp(user_query, user_id)
            if mcp_result:
                self._auto_save(f"ASSISTANT: {mcp_result}", user_id, "response")
                return {"reply": mcp_result, "privacy_mode": "tools", "model_used": "mcp", "context_used": 0, "tag": self._make_tag("tools", "mcp", 0)}
            # Fallback на планировщик если прямой диспатч не сработал
            ag = await self._agent_run(user_query, user_id, {"rag_results":[]})
            if ag and not ag.startswith("⚠️"):
                self._auto_save(f"ASSISTANT: {ag}", user_id, "response")
                return {"reply": ag, "privacy_mode": "tools", "model_used": "agent", "context_used": 0, "tag": self._make_tag("tools", "agent", 0)}
        
        # === 2. Явный режим из сессии или переопределение ===
        mode = intent_override or force_mode or session["mode"]
        
        # === 3. Прямой возврат из RAG ===
        if mode == "rag_direct" or (mode == "auto" and any(k in user_query.lower() for k in ["покажи мой","напомни мой","что я сохранял"])):
            vec = self.embedder.embed([user_query])[0]
            res = self.store.search(vec, limit=5)
            found = [(r.get("payload") or r.get("meta") or {}).get("text","").replace("USER: ","").replace("ASSISTANT: ","") for r in res if (r.get("payload") or r.get("meta") or {}).get("user_id") in (None, user_id)]
            if found:
                reply = "Найдено:\n" + "\n".join(f"• {t}" for t in found[:3])
                self._auto_save(f"ASSISTANT: {reply}", user_id, "response")
                return {"reply": reply, "privacy_mode": "rag_direct", "model_used": "rag", "context_used": len(found), "tag": self._make_tag("rag_direct", "rag", len(found))}
        
        # === 4. Прямой MCP для путей (авто) ===
        if mode == "auto":
            mcp_result = await self._try_direct_mcp(user_query, user_id)
            if mcp_result:
                self._auto_save(f"ASSISTANT: {mcp_result}", user_id, "response")
                return {"reply": mcp_result, "privacy_mode": "tools", "model_used": "mcp", "context_used": 0, "tag": self._make_tag("tools", "mcp", 0)}
        
        # === 5. Интент-роутинг с уверенностью ===
        if mode == "auto":
            intent, confidence, reason = intent_router.classify(user_query)
            logging.info(f"Intent: {intent}, confidence: {confidence}, reason: {reason}")
            
            # Если неуверенность — запрашиваем уточнение
            if intent_router.needs_clarification(intent, confidence, user_query):
                options = intent_router.get_clarification_options(user_query)
                session_manager.set_pending(user_id, user_query, options)
                return {
                    "reply": f"Не совсем понял. Что хотите сделать?",
                    "needs_clarification": True,
                    "clarification_options": options,
                    "privacy_mode": "unknown", "model_used": "router", "context_used": 0, "tag": "[❓]"
                }
            
            # Применяем детектированный интент
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
            elif intent == "web_search":
                # Поиск в интернете через MCP + синтез
                tool = "mcp_github_search_repositories" if "github" in user_query.lower() else None
                # (можно расширить на другие веб-инструменты)
                # Fallback на LLM с веб-контекстом
                pass
        
        # === 6. Fallback: обычный LLM-поток с чатом + RAG ===
        privacy_mode = self.router.classify(user_query)
        prompt = user_query
        tokens = {}
        if privacy_mode == "CLOUD" and self.router.needs_scrubbing(user_query):
            prompt, tokens = self.vault.scrub(user_query)
        
        vec = self.embedder.embed([prompt])[0]
        ctx_texts = [(r.get("payload") or r.get("meta") or {}).get("text","") for r in self.store.search(vec, limit=5)]
        
        system = "Отвечай кратко и по делу. Используй контекст если релевантен."
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
echo "✅ orchestrator: гибридный роутинг"

echo "[5/6] Registry: фикс импорта сессии..."
# Добавляем импорт session_manager в registry если нужно
sed -i '/from agents.brain.registry import registry/a from agents.brain.session import session_manager' agents/main/orchestrator.py 2>/dev/null || true
echo "✅ registry imports"

echo "[6/6] Перезапуск..."
pkill -f uvicorn 2>/dev/null || true; sleep 3
set -a; source $BASE/.env; set +a
cd $BASE/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health && echo "✅ API UP" || echo "❌ API DOWN"

echo ""
echo "🎉 Гибридный роутинг готов!"
echo ""
echo "🧪 Тесты в Telegram:"
echo "  1. 'привет' → 💬 чат (авто)"
echo "  2. 'Покажи файлы в /home/der' → 🛠️ MCP (авто, распознал путь)"
echo "  3. 'Напомни мой пароль' → 🗄️ прямой поиск в памяти"
echo "  4. Если система не уверена → ❓ кнопки уточнения"
echo "  5. Кнопка '🛠️ Агент-режим' → форс инструментов"
echo ""
echo "📋 Команды:"
echo "  /mode auto|chat|tools|rag|web  — зафиксировать режим"
echo "  /start — показать меню с кнопками"
echo ""
echo "ЖДУ: тесты или ОК."
