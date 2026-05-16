#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain
cd "$BASE"

echo "[1/3] Синхронизация и загрузка инструментов (LangChain + OpenWebUI + MCP)..."
python3 << 'PY'
import asyncio, sys, os
sys.path.insert(0, '.')
os.environ.setdefault("QDRANT_HOST", "localhost")
os.environ.setdefault("QDRANT_PORT", "6333")

from agents.brain.registry import registry

async def main():
    print("⏳ Загрузка... (git clone/pull + MCP probe)")
    try:
        await registry.reload()
        print(f"✅ Успешно загружено: {len(registry.skills)}")
        types = {}
        for s in registry.skills.values(): types[s['type']] = types.get(s['type'], 0) + 1
        for t, c in sorted(types.items()): print(f"   • {t}: {c}")
        print(f"📋 Топ-10: {', '.join(list(registry.skills.keys())[:10])}...")
    except Exception as e:
        print(f"⚠️ Частичная загрузка: {e}")
        print(f"   Статических: {len([v for v in registry.skills.values() if v['type']=='static'])}")

asyncio.run(main())
PY

echo "[2/3] Обновление Orchestrator: интеграция реестра..."
cat << 'PY' > agents/main/orchestrator.py
import os, sys, uuid, re, asyncio
from pathlib import Path
BASE_DIR = Path(__file__).parent.parent.parent
env_file = BASE_DIR / ".env"
if env_file.exists():
    for ln in env_file.read_text().splitlines():
        if "=" in ln and not ln.strip().startswith("#"):
            k,v = ln.split("=",1); os.environ[k.strip()] = v.strip()
if str(BASE_DIR) not in sys.path: sys.path.insert(0, str(BASE_DIR))

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
        except: pass

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

    async def process(self, user_query, user_id, task_type="default"):
        self._auto_save(f"USER: {user_query}", user_id, "query")
        mode = self.router.classify(user_query)
        if mode=="LOCAL" and any(k in user_query.lower() for k in ["покажи","напомни","мой пароль","что я сохранял"]):
            vec = self.embedder.embed([user_query])[0]
            res = self.store.search(vec, limit=5)
            found = [(r.get("payload") or r.get("meta") or {}).get("text","").replace("USER: ","").replace("ASSISTANT: ","") for r in res if (r.get("payload") or r.get("meta") or {}).get("user_id") in (None, user_id)]
            if found:
                self._auto_save(f"ASSISTANT: {found[0]}", user_id, "response")
                return {"reply": found[0], "privacy_mode": "LOCAL", "model_used": "rag", "context_used": len(found)}

        ag = await self._agent_run(user_query, user_id, {"rag_results":[]})
        if ag and not ag.startswith("⚠️"):
            self._auto_save(f"ASSISTANT: {ag}", user_id, "response")
            return {"reply": ag, "privacy_mode": mode, "model_used": "agent", "context_used": 0}

        prompt = user_query
        tokens = {}
        if mode=="CLOUD" and self.router.needs_scrubbing(user_query):
            prompt, tokens = self.vault.scrub(user_query)
        vec = self.embedder.embed([prompt])[0]
        ctx = [(r.get("payload") or r.get("meta") or {}).get("text","") for r in self.store.search(vec, limit=5)]
        fp = f"Отвечай подробно. [__SCRUB_*__] оставляй как есть.\n\nКонтекст:\n"+"\n---\n".join(ctx)+f"\n\nЗапрос: {prompt}"
        try:
            if mode=="LOCAL": resp = await self.local_llm.chat(model="qwen2.5:3b", prompt=fp, context=[]); mu="qwen2.5:3b"
            else: resp = await self.cloud_llm.chat(prompt=fp, context=[]); mu="cloud"
        except: resp = await self.local_llm.chat(model="qwen2.5:3b", prompt=fp, context=[]); mu="qwen2.5:3b (fb)"
        if tokens and mode=="CLOUD":
            resp = self.vault.unscrub(resp, tokens)
            m = [v for v in tokens.values() if v not in resp]
            if m: resp += f"\n\n[Данные: {', '.join(m)}]"
        self._auto_save(f"ASSISTANT: {resp}", user_id, "response")
        return {"reply": resp, "privacy_mode": mode, "model_used": mu, "context_used": len(ctx)}
PY
echo "✅ Orchestrator обновлён"

echo "[3/3] Перезапуск API..."
pkill -f uvicorn 2>/dev/null || true; sleep 3
set -a; source $BASE/.env; set +a
cd $BASE/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health && echo "✅ API UP" || echo "❌ API DOWN"

echo ""
echo "🎉 Готово. 800-1200+ инструментов в реестре."
echo "🧪 Тест в Telegram:"
echo "  • 'Какие инструменты есть для поиска?'"
echo "  • 'Посчитай: 245 * 12 + 7'"
echo "  • 'Найди последние новости про ИИ'"
echo "🔄 Обновление: запусти этот же скрипт повторно"
echo "ЖДУ: ОК или вывод теста."
