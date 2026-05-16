#!/bin/bash
set -e
cd ~/magic-brain

echo "[1/4] Предзагрузка модели (чтобы не грузилась при запросе)..."
ollama ps 2>/dev/null | grep qwen || ollama run qwen2.5:3b "ok" > /dev/null 2>&1 &
sleep 8
curl -sf http://localhost:11434/api/chat -d '{"model":"qwen2.5:3b","messages":[{"role":"user","content":"ok"}],"stream":false}' >/dev/null && echo "✅ Ollama warmed up" || echo "⚠️ Ollama warmup slow"

echo "[2/4] Быстрый автономный роутер (без LLM-парсера)..."
cat << 'PY' > agents/brain/tool_router.py
import re, json, logging
from typing import List, Dict, Optional

class FastToolRouter:
    """Автономный выбор инструмента по ключевым словам + извлечение аргументов из схемы"""
    def select(self, query: str, tools: List[Dict]) -> Optional[Dict]:
        q = query.lower()
        best_score, best_tool, best_args = 0, None, {}
        
        for tool in tools:
            tname, tdesc, params = tool["name"], tool.get("desc","").lower(), tool.get("params",{})
            score = 0
            
            # 1. Совпадение по описанию
            for word in re.findall(r'[а-яa-z]{3,}', q):
                if word in tdesc: score += 2
            # 2. Совпадение по имени
            if tname in q: score += 5
            # 3. Контекст пути
            if ("path" in params or "file" in tname) and ("/" in q or "~/" in q or "файл" in q or "каталог" in q or "покажи" in q):
                score += 10
            
            if score > best_score:
                best_score = score
                best_tool = tname
                # Извлекаем аргументы
                args = {}
                for pname, pschema in params.items():
                    if pname == "path":
                        m = re.search(r'(/[a-zA-Z0-9./_~-]+|~/[a-zA-Z0-9./_~-]+)', query)
                        args["path"] = m.group(0) if m else "/home/der"
                    elif pname == "content" or pname == "text":
                        m = re.search(r'(?:напиши туда|запиши|содержимое|текст|скажи)[:\s]*(.+)', query, re.I|re.DOTALL)
                        args["content"] = m.group(1).strip() if m else query
                    elif pname == "query":
                        m = re.search(r'(?:про|о|найти|ищи)\s+(.+)', query, re.I)
                        args["query"] = m.group(1).strip() if m else q
                    else:
                        m = re.search(rf'{pname}[:\s]*([^\s,;]+)', query, re.I)
                        if m: args[pname] = m.group(1)
                best_args = args
        
        if best_score >= 3:
            return {"tool_name": best_tool, "args": best_args}
        return None

tool_router = FastToolRouter()
PY
echo "✅ tool_router.py"

echo "[3/4] Orchestrator: строгие таймауты + вызов роутера..."
cat << 'PY' > agents/main/orchestrator.py
import os, sys, time, asyncio, logging, re
from pathlib import Path
BASE = Path(__file__).parent.parent.parent; sys.path.insert(0, str(BASE))
for ln in (BASE/".env").read_text().splitlines():
    if "=" in ln and not ln.strip().startswith("#"): k,v=ln.split("=",1); os.environ[k.strip()]=v.strip()
logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s', force=True)

from rag.router.privacy_router import PrivacyRouter
from rag.embed.local_embedder import LocalEmbedder
from rag.store.qdrant_client import RAGStore
from privacy.local_llm.ollama_client import OllamaClient
from privacy.local_llm.openrouter_client import OpenRouterClient
from privacy.vault.token_vault import TokenVault
from agents.brain.registry import registry
from agents.brain.tool_router import tool_router
from agents.mcp.client import mcp as mcp_direct

class MagicBrain:
    def __init__(self):
        self.router=PrivacyRouter(); self.embedder=LocalEmbedder(); self.store=RAGStore()
        self.local_llm=OllamaClient(); self.cloud_llm=OpenRouterClient(api_key=os.getenv("OPENROUTER_API_KEY"))
        self.vault=TokenVault()

    def _tag(self, m, mdl, c): return f"[{'🛠️' if m=='tools' else '💬'}{mdl}{' +RAG:'+str(c) if c else ''}]"

    async def _agent_execute(self, q, uid):
        await registry.wait_ready(timeout=5)
        tools = registry.list(q)[:10]
        if not tools: return None
        meta = [{"name":t, "desc":registry.skills[t].get("desc",""), "params":registry.skills[t].get("params",{})} for t in tools if t in registry.skills]
        
        logging.info(f"🔍 Router input: {len(meta)} tools")
        dec = tool_router.select(q, meta)
        if not dec: logging.info("⚠️ No tool matched"); return None
        logging.info(f"🎯 Selected: {dec['tool_name']} | args: {dec['args']}")
        
        skill = registry.skills.get(dec["tool_name"])
        if skill and callable(skill.get("func")):
            res = await asyncio.wait_for(skill["func"](q, {}, uid, **dec["args"]), timeout=15)
        else:
            res = await asyncio.wait_for(mcp_direct.execute(dec["tool_name"], dec["args"]), timeout=15)
        return str(res) if res else f"✅ {dec['tool_name']} done"

    async def _chat_fallback(self, q, uid, start):
        if time.time()-start > 20: return "⏱️ Таймаут", "timeout", 0
        try:
            pm = self.router.classify(q)
            p, tok = q, {}
            if pm=="CLOUD" and self.router.needs_scrubbing(q): p, tok = self.vault.scrub(q)
            fp = f"Отвечай кратко.\nЗапрос: {p}"
            if pm=="LOCAL":
                r = await asyncio.wait_for(self.local_llm.chat(model="qwen2.5:3b", prompt=fp, context=[]), timeout=10)
                return r, "qwen2.5:3b", 0
            else:
                r = await asyncio.wait_for(self.cloud_llm.chat(prompt=fp, context=[]), timeout=10)
                if tok: r = self.vault.unscrub(r, tok)
                return r, "cloud", 0
        except asyncio.TimeoutError: return "⏱️ Таймаут", "timeout", 0
        except: return "⚠️ Ошибка LLM", "error", 0

    async def process(self, user_query, user_id, force_mode=None, force_agent=False, **kw):
        start = time.time()
        if force_agent or force_mode=="tools":
            res = await self._agent_execute(user_query, user_id)
            if res and not res.startswith("⚠️"):
                return {"reply":res, "privacy_mode":"tools", "model_used":"agent", "context_used":0, "tag":self._tag("tools","agent",0)}
        txt, mu, c = await self._chat_fallback(user_query, user_id, start)
        pm = "LOCAL" if mu=="qwen2.5:3b" else "CLOUD"
        return {"reply":txt, "privacy_mode":pm, "model_used":mu, "context_used":c, "tag":self._tag("chat",mu,c)}
PY
echo "✅ orchestrator.py"

echo "[4/4] Перезапуск API + тест..."
pkill -f "uvicorn.*:8000" 2>/dev/null || true; sleep 2
cd ~/magic-brain/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 5

echo ""
echo "=== ТЕСТ ==="
curl -s -X POST http://127.0.0.1:8000/process \
  -H "Content-Type: application/json" \
  -d '{"user_id": 999, "text": "Покажи файлы в /home/der", "force_mode": "tools"}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('tag:', d.get('tag')); print('model:', d.get('model_used')); print('reply:', d.get('reply','')[:150].replace('\n',' '))"

echo ""
echo "=== ЛОГИ ==="
tail -10 /tmp/api.log | grep -E 'Router|Selected|Executing|timeout|ERROR' || echo "(нет)"
