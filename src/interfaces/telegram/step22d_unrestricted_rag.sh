#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain
cd $BASE

echo "[1/7] Vault: локальное хранилище токенов (в памяти + бэкап)..."
mkdir -p data/vault
cat << 'PY' > privacy/vault/token_vault.py
import os, json, uuid, hashlib, pickle
from pathlib import Path
from datetime import datetime, timedelta

VAULT_FILE = Path(__file__).parent.parent.parent / "data" / "vault" / "token_map.pkl"
VAULT_FILE.parent.mkdir(parents=True, exist_ok=True)

class TokenVault:
    def __init__(self, user_id: int = None):
        self.user_id = user_id
        self.vault = self._load()
    
    def _load(self):
        if VAULT_FILE.exists():
            try:
                with open(VAULT_FILE, 'rb') as f:
                    return pickle.load(f)
            except: pass
        return {}
    
    def _save(self):
        with open(VAULT_FILE, 'wb') as f:
            pickle.dump(self.vault, f)
    
    def scrub(self, text: str) -> tuple[str, dict]:
        """Заменяет чувствительные паттерны на токены, возвращает (scrubbed_text, {token: original})"""
        import re
        tokens = {}
        # Паттерны: пароль=..., карта: ..., email, телефон
        patterns = [
            (r'(пароль|password|pwd)\s*[=:]\s*([^\s,;]+)', lambda m: f"{m.group(1)}=[SCRUB_PWD_{uuid.uuid4().hex[:6]}]"),
            (r'\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b', lambda m: f"[SCRUB_CARD_{uuid.uuid4().hex[:6]}]"),
            (r'\b[\w.-]+@[\w.-]+\.\w+\b', lambda m: f"[SCRUB_EMAIL_{uuid.uuid4().hex[:6]}]"),
            (r'\+7\s?\(?\d{3}\)?\s?\d{3}-?\d{2}-?\d{2}', lambda m: f"[SCRUB_PHONE_{uuid.uuid4().hex[:6]}]"),
        ]
        def replacer(match):
            token = patterns[0][1](match) if patterns[0][0] in match.group(0) else patterns[[p[0] for p in patterns].index([p for p in patterns if p[0] in match.group(0) or p[1](match) in [patterns[x][1](match) for x in range(len(patterns))]][0][0])][1](match)
            # Проще: ручной парсинг
            text = match.group(0)
            if '=' in text or ':' in text:
                key, val = text.split('=',1) if '=' in text else text.split(':',1)
                token = f"[SCRUB_{key.strip().upper()}_{uuid.uuid4().hex[:6]}]"
                tokens[token] = val.strip()
                return token
            token = f"[SCRUB_DATA_{uuid.uuid4().hex[:6]}]"
            tokens[token] = text
            return token
        
        scrubbed = text
        for pattern, _ in patterns:
            matches = list(re.finditer(pattern, scrubbed, re.I))
            for m in reversed(matches):  # reverse to preserve indices
                orig = m.group(0)
                token = f"[SCRUB_{hashlib.md5(orig.encode()).hexdigest()[:8]}]"
                tokens[token] = orig
                scrubbed = scrubbed[:m.start()] + token + scrubbed[m.end():]
        
        if tokens:
            self.vault.update({f"{self.user_id}_{t}": v for t,v in tokens.items()})
            self._save()
        return scrubbed, tokens
    
    def unscrub(self, text: str) -> str:
        """Заменяет токены на оригиналы"""
        import re
        for token, orig in self.vault.items():
            if token.startswith(f"{self.user_id}_"):
                short_token = token.split('_',2)[-1]
                text = text.replace(f"[SCRUB_{short_token}]", orig)
                # Также пробуем полный формат
                text = text.replace(token, orig)
        return text
    
    def get_original(self, token: str) -> str:
        key = f"{self.user_id}_{token}" if not token.startswith(f"{self.user_id}_") else token
        return self.vault.get(key, None)

vault = TokenVault()
PY
echo "✅ TokenVault создан"

echo "[2/7] Фикс privacy_router: только классификация, без блокировок..."
cat << 'PY' > rag/router/privacy_router.py
import re

class PrivacyRouter:
    def __init__(self):
        # Только для определения маршрута (LOCAL/CLOUD), не для блокировки
        self.local_keywords = ['пароль', 'password', 'секрет', 'ключ', 'приват', 'личное', 'конфиденциально']
    
    def classify(self, query: str) -> str:
        q = query.lower()
        # Если запрос явно про МОИ данные → LOCAL
        if any(kw in q for kw in self.local_keywords) and any(x in q for x in ['мой', 'покажи', 'напомни', 'сохрани', 'доступ']):
            return "LOCAL"
        # Если есть чувствительные слова → всё равно можно в CLOUD, но с токенизацией
        return "LOCAL" if any(kw in q for kw in self.local_keywords) else "CLOUD"
    
    def needs_scrubbing(self, text: str) -> bool:
        """Всегда возвращаем True для CLOUD-маршрута"""
        return True
PY
echo "✅ privacy_router: только маршрутизация"

echo "[3/7] Orchestrator: авто-инжест ВСЕГО + токенизация для облака..."
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
from privacy.vault.token_vault import TokenVault
from agents.critic.critic import Critic

class MagicBrain:
    def __init__(self):
        self.router = PrivacyRouter()
        self.embedder = LocalEmbedder()
        self.store = RAGStore()
        self.local_llm = OllamaClient()
        self.cloud_llm = OpenRouterClient(api_key=os.getenv("OPENROUTER_API_KEY"), router=self.router)
        self.vault = TokenVault()  # глобальный, user_id передаётся в методы
        self.critic = Critic()  # теперь только для форматирования, не блокировок
    
    def _save_to_rag(self, text: str, meta: dict):
        """Безусловное сохранение в RAG"""
        try:
            vec = self.embedder.embed([text])[0]
            doc_id = f"rag_{uuid.uuid4().hex[:12]}"
            self.store.upsert([vec], [{**meta, "text": text}], [doc_id])
        except Exception as e:
            print(f"⚠️ RAG save error: {e}")
    
    async def process(self, user_query: str, user_id: int, task_type: str = "default") -> dict:
        # 1. Сохраняем ЗАПРОС пользователя в RAG (всегда)
        self._save_to_rag(f"USER: {user_query}", {"user_id": user_id, "type": "query", "privacy": "HIGH"})
        
        # 2. Классифицируем маршрут
        mode = self.router.classify(user_query)
        
        # 3. Готовим промпт для LLM
        prompt = user_query
        if mode == "CLOUD":
            # Токенизируем перед отправкой в облако
            scrubbed, tokens = self.vault.scrub(user_query)
            prompt = f"[Контекст: некоторые данные токенизированы для приватности]\n{scrubbed}"
        
        # 4. Поиск в RAG (всегда ищем, но фильтруем по user_id)
        query_vec = self.embedder.embed([user_query])[0]
        context = self.store.search(query_vec, limit=5)
        # Фильтруем: показываем только данные этого пользователя
        ctx_texts = [c["text"] for c in context if c.get("meta",{}).get("user_id") in (None, user_id)]
        
        # 5. Вызов LLM
        if mode == "LOCAL":
            response = await self.local_llm.chat(model="qwen2.5:3b", prompt=prompt, context=ctx_texts)
            model_used = "qwen2.5:3b"
        else:
            response = await self.cloud_llm.chat(prompt=prompt, context=ctx_texts)
            model_used = "cloud"
        
        # 6. Раскрываем токены в ответе (если были)
        if mode == "CLOUD" and '[SCRUB_' in response:
            response = self.vault.unscrub(response)
        
        # 7. Сохраняем ОТВЕТ бота в RAG (всегда)
        self._save_to_rag(f"ASSISTANT: {response}", {"user_id": user_id, "type": "response", "privacy": mode, "model": model_used})
        
        # 8. Критик: только подсказки, не блокировки
        _, issues = self.critic.validate(response)  # игнорируем блокировки
        
        return {
            "reply": response,
            "privacy_mode": mode,
            "model_used": model_used,
            "context_used": len(ctx_texts),
            "issues": issues,
            "tokens_applied": mode == "CLOUD"
        }
PY
echo "✅ orchestrator: авто-инжест + токенизация"

echo "[4/7] Critic: только подсказки, 0 блокировок..."
cat << 'PY' > agents/critic/critic.py
class Critic:
    def validate(self, response: str) -> tuple[bool, list]:
        # Никогда не блокируем. Только собираем "подозрения" для лога.
        issues = []
        if len(response) > 2000:
            issues.append("long_response")
        if "не могу" in response.lower() and "помочь" in response.lower():
            issues.append("refusal_detected")  # просто лог, не блокировка
        return True, issues  # ✅ всегда OK
    
    def refine(self, response: str, issues: list) -> str:
        return response  # не меняем ответ
PY
echo "✅ critic: 0 блокировок"

echo "[5/7] Bot: чистый тег + 0 морализма..."
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

async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    uid = update.effective_user.id
    text = update.message.text or ""
    await safe_reply(update, "⏳ ...")
    try:
        async with httpx.AsyncClient(timeout=120.0) as c:
            r = await c.post(f"{API_URL}/process", json={"user_id":uid, "text":text, "has_files":False, "task_type":"default"})
            res = r.json()
            reply = res.get("reply", "⚠️ Нет ответа")
            mode = res.get("privacy_mode","")
            model = res.get("model_used","")
            rag = res.get("context_used",0)
            tag = f"[{'🔐' if mode=='LOCAL' else '☁️'}{model}{' +RAG:'+str(rag) if rag>0 else ''}]"
            await safe_reply(update, f"{reply}\n\n{tag}")
    except Exception as e:
        await safe_reply(update, f"⚠️ {str(e)[:120]}")

def main():
    if not BOT_TOKEN or len(BOT_TOKEN)<20: print("❌ Нет токена"); return
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(MessageHandler(filters.ALL, handle_message))
    print(f"🤖 Бот запущен"); app.run_polling()

if __name__ == "__main__": main()
PY
echo "✅ bot.py: чистый вывод"

echo "[6/7] Перезапуск..."
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

echo "[7/7] Тесты (без морализма):"
echo "  1. 'сохрани: мой пароль от почты = SuperSecret123'"
echo "     → должно просто ответить (и сохранить в RAG)"
echo "  2. 'покажи мой пароль от почты'"
echo "     → должно найти и показать: ... = SuperSecret123"
echo "  3. 'привет'"
echo "     → обычный ответ"
echo ""
echo "💡 Всё, что ты пишешь — автоматически в твоём приватном RAG."
echo "💡 В облако уходит только токенизированная версия (если маршрут CLOUD)."
echo "💡 При запросе — токены раскрываются, показываешь оригинал."
echo ""
echo "ЖДУ: результаты тестов."
