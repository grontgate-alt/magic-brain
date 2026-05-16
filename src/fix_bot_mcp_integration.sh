#!/bin/bash
set -e
cd ~/magic-brain

echo "[1/3] Фикс Worker: не парсить JSON из MCP..."
cat << 'PY' > agents/brain/worker.py
import asyncio, time, re, json
from typing import Optional, Dict, Any

class Worker:
    def __init__(self, orchestrator):
        self.orch = orchestrator
        self.timeout = 60

    async def execute(self, step: Dict, context: Dict, user_id: int) -> Dict[str, Any]:
        start = time.time()
        skill_name = step.get("skill")
        desc = step.get("desc", "")
        
        try:
            # === MCP-инструменты ===
            if skill_name and skill_name.startswith("mcp_"):
                args = self._parse_mcp_args(desc, skill_name)
                # Вызываем обёртку из registry
                skill_meta = self.orch.registry.get(skill_name)
                if not skill_meta or not callable(skill_meta["func"]):
                    return {"success": False, "result": None, "error": f"Skill not found: {skill_name}", "duration": time.time() - start}
                
                raw_result = await asyncio.wait_for(
                    skill_meta["func"](desc, context, user_id, **args),
                    timeout=self.timeout
                )
                # ✅ MCP возвращает plain text — НЕ парсим как JSON
                result = str(raw_result) if raw_result else "✅ Выполнено"
                return {"success": True, "result": result, "skill_used": skill_name, "duration": time.time() - start, "error": None}
            
            # === Обычные скиллы ===
            if skill_name:
                skill = self.orch.registry.get(skill_name)
                if skill and callable(skill["func"]):
                    args = {"query": desc, "context": context, "user_id": user_id}
                    raw = await asyncio.wait_for(skill["func"](**args), timeout=self.timeout)
                    result = str(raw) if raw else "✅ Выполнено"
                    return {"success": True, "result": result, "skill_used": skill_name, "duration": time.time() - start, "error": None}
            
            # === Fallback на LLM ===
            result = await self._fallback_llm(desc, context, user_id)
            return {"success": True, "result": result, "skill_used": "fallback_llm", "duration": time.time() - start, "error": None}
            
        except asyncio.TimeoutError:
            return {"success": False, "result": None, "error": f"timeout>{self.timeout}s", "duration": time.time() - start}
        except Exception as e:
            return {"success": False, "result": None, "error": f"{type(e).__name__}: {str(e)[:200]}", "duration": time.time() - start}
    
    def _parse_mcp_args(self, desc: str, tool_name: str) -> dict:
        args = {}
        if "filesystem" in tool_name:
            paths = re.findall(r'(/[^\s,;"]+|~/[^\s,;"]+)', desc)
            if paths: args["path"] = paths[0]
            if "read" in tool_name and "path" not in args:
                args["path"] = os.path.expanduser("~")
        if "github" in tool_name:
            match = re.search(r'(?:репозиторий|поиск|запрос|про)\s+([^\s,;.!"]{3,})', desc, re.I)
            if match: args["query"] = match.group(1)
        if "query" not in args and "path" not in args:
            args["query"] = desc[:200]
        return args

    async def _fallback_llm(self, desc: str, context: Dict, user_id: int) -> str:
        ctx_text = "\n".join(context.get("rag_results", [])[:3]) if context else ""
        prompt = f"Контекст:\n{ctx_text}\n\nЗадача: {desc}\n\nОтвет:"
        if hasattr(self.orch, 'local_llm'):
            return await self.orch.local_llm.chat(model="qwen2.5:3b", prompt=prompt, context=[])
        return f"[Выполнено: {desc[:50]}...]"
PY
echo "✅ Worker fixed"

echo "[2/3] Фикс Orchestrator: логирование + защита от JSON-ошибок..."
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
        logging.info(f"Process: user={user_id}, query={user_query[:100]}")
        self._auto_save(f"USER: {user_query}", user_id, "query")
        mode = self.router.classify(user_query)
        
        # Прямой возврат из RAG
        if mode=="LOCAL" and any(k in user_query.lower() for k in ["покажи","напомни","мой пароль","что я сохранял"]):
            vec = self.embedder.embed([user_query])[0]
            res = self.store.search(vec, limit=5)
            found = [(r.get("payload") or r.get("meta") or {}).get("text","").replace("USER: ","").replace("ASSISTANT: ","") for r in res if (r.get("payload") or r.get("meta") or {}).get("user_id") in (None, user_id)]
            if found:
                self._auto_save(f"ASSISTANT: {found[0]}", user_id, "response")
                return {"reply": found[0], "privacy_mode": "LOCAL", "model_used": "rag", "context_used": len(found)}

        # Агентский режим
        ag = await self._agent_run(user_query, user_id, {"rag_results":[]})
        if ag and not ag.startswith("⚠️"):
            logging.info(f"Agent result: {ag[:100]}")
            self._auto_save(f"ASSISTANT: {ag}", user_id, "response")
            return {"reply": ag, "privacy_mode": mode, "model_used": "agent", "context_used": 0}

        # Fallback: обычный LLM-поток
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
        except Exception as e:
            logging.warning(f"LLM error: {e}")
            resp = await self.local_llm.chat(model="qwen2.5:3b", prompt=fp, context=[]); mu="qwen2.5:3b (fb)"
        
        # Де-токенизация
        if tokens and mode=="CLOUD":
            resp = self.vault.unscrub(resp, tokens)
            m = [v for v in tokens.values() if v not in resp]
            if m: resp += f"\n\n[Данные: {', '.join(m)}]"
        
        self._auto_save(f"ASSISTANT: {resp}", user_id, "response")
        return {"reply": resp, "privacy_mode": mode, "model_used": mu, "context_used": len(ctx)}
PY
echo "✅ Orchestrator fixed"

echo "[3/3] Перезапуск API..."
pkill -f uvicorn 2>/dev/null || true; sleep 3
set -a; source ~/magic-brain/.env; set +a
cd ~/magic-brain/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health && echo "✅ API UP" || echo "❌ API DOWN"

echo ""
echo "🧪 Тест через бота (напиши в Telegram):"
echo "  • 'Покажи файлы в /home/der'"
echo "  • 'Прочитай ~/magic-brain/.env'"
echo ""
echo "Если ошибка — скинь: tail -30 /tmp/api.log"
echo "ЖДУ: результат."
