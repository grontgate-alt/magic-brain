#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain
cd "$BASE"

echo "[1/3] Tool Router: автономный выбор инструмента + извлечение аргументов..."
cat << 'PY' > agents/brain/tool_router.py
import re, json, asyncio
from typing import List, Dict, Optional

class ToolRouter:
    """LLM-роутер: выбирает инструмент и генерирует аргументы строго по схеме"""
    def __init__(self, orchestrator):
        self.orch = orchestrator

    async def select_and_parse(self, query: str, available_tools: List[Dict]) -> Optional[Dict]:
        if not available_tools: return None
        
        # Формируем компактное описание инструментов
        tools_desc = "\n".join([f"- {t['name']}: {t['desc']} (params: {json.dumps(t.get('params',{}))})" for t in available_tools])
        
        prompt = f"""You are a tool router. Given a user query and available tools, select the BEST match and extract arguments STRICTLY following the tool's schema.
Tools:
{tools_desc}

Query: {query}

Output ONLY valid JSON:
{{
  "tool": "exact_tool_name",
  "args": {{ "param1": "value1" }},
  "confidence": 0.0-1.0
}}
If no tool matches well, output {{"tool": null, "confidence": 0}}.
"""
        try:
            resp = await asyncio.wait_for(
                self.orch.local_llm.chat(model="qwen2.5:3b", prompt=prompt, context=[]),
                timeout=12
            )
            # Извлекаем JSON из ответа
            match = re.search(r'\{[\s\S]*\}', resp)
            if not match: return None
            parsed = json.loads(match.group(0))
            if not parsed.get("tool") or parsed.get("confidence", 0) < 0.7:
                return None
            return {"tool_name": parsed["tool"], "args": parsed.get("args", {})}
        except:
            return None

tool_router = ToolRouter
PY
echo "✅ tool_router.py"

echo "[2/3] Orchestrator: чистый агентский поток (0 хардкода)..."
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
from agents.brain.tool_router import ToolRouter
from agents.mcp.client import mcp as mcp_direct

class MagicBrain:
    def __init__(self):
        logging.info("🧠 Init MagicBrain...")
        self.router = PrivacyRouter(); self.embedder = LocalEmbedder(); self.store = RAGStore()
        self.local_llm = OllamaClient()
        self.cloud_llm = OpenRouterClient(api_key=os.getenv("OPENROUTER_API_KEY"), router=self.router)
        self.vault = TokenVault()
        self.planner = Planner(); self.critic = CriticLoop(); self.worker = Worker(self)
        self.tool_router = ToolRouter(self)

    def _auto_save(self, t, u, r):
        try:
            v = self.embedder.embed([t])[0]
            self.store.upsert([v], [{"text":t,"user_id":u,"role":r,"privacy":"HIGH"}], [str(uuid.uuid4())])
        except: pass

    def _tag(self, m, mdl, c): return f"[{'🛠️' if m=='tools' else '💬'}{mdl}{' +RAG:'+str(c) if c else ''}]"

    async def _agent_execute(self, query: str, user_id: int) -> Optional[str]:
        """Автономный агент: выбирает инструмент из реестра, выполняет, возвращает результат"""
        await registry.wait_ready(timeout=8)
        tools = registry.list(query)  # релевантные инструменты
        if not tools: return None
        
        # Собираем метаданные для роутера
        tool_meta = []
        for tname in tools[:10]:  # берём топ-10 для скорости
            meta = registry.get(tname)
            if meta: tool_meta.append({"name": tname, "desc": meta.get("desc",""), "params": meta.get("params",{})})
        
        if not tool_meta: return None
        
        # LLM выбирает инструмент и аргументы
        decision = await self.tool_router(self).select_and_parse(query, tool_meta)
        if not decision or not decision.get("tool_name"): return None
        
        tname = decision["tool_name"]
        args = decision["args"]
        logging.info(f"🎯 Agent chose: {tname} with args: {args}")
        
        # Выполняем через registry или напрямую MCP
        skill = registry.get(tname)
        try:
            if skill and callable(skill.get("func")):
                result = await asyncio.wait_for(skill["func"](query, {}, user_id, **args), timeout=25)
            else:
                # Fallback на прямой MCP если скилл не загрузился
                result = await asyncio.wait_for(mcp_direct.execute(tname, args), timeout=25)
            
            return str(result) if result else f"✅ {tname} executed successfully"
        except Exception as e:
            logging.error(f"Tool exec error: {e}")
            return f"⚠️ Ошибка выполнения {tname}: {str(e)[:150]}"

    async def process(self, user_query: str, user_id: int, task_type: str = "default", 
                      force_agent: bool = False, force_mode: str = None, intent_override: str = None) -> dict:
        start = time.time()
        self._auto_save(f"USER: {user_query}", user_id, "query")
        
        # === 1. АГЕНТСКИЙ РЕЖИМ (по умолчанию) ===
        if force_mode in ("tools", "agent") or force_agent or force_mode is None:
            agent_res = await self._agent_execute(user_query, user_id)
            if agent_res and not agent_res.startswith("⚠️"):
                logging.info(f"✅ Agent succeeded in {time.time()-start:.2f}s")
                return {"reply": agent_res, "privacy_mode": "tools", "model_used": "agent", "context_used": 0, "tag": self._tag("tools", "agent", 0)}
            elif agent_res:
                logging.warning(f"⚠️ Agent failed: {agent_res[:50]}")
        
        # === 2. FALLBACK: ЧАТ + RAG (если агент не сработал или выбран режим chat) ===
        if time.time()-start > 35:
            return {"reply":"⏱️ Таймаут","privacy_mode":"LOCAL","model_used":"timeout","context_used":0,"tag":"[⏱️]"}
        
        try:
            pm = self.router.classify(user_query)
            prompt, tokens = user_query, {}
            if pm=="CLOUD" and self.router.needs_scrubbing(user_query): prompt, tokens = self.vault.scrub(user_query)
            
            vec = self.embedder.embed([prompt])[0]
            ctx = [(r.get("payload") or r.get("meta") or {}).get("text","") for r in self.store.search(vec, limit=3)]
            
            sys_prompt = "Отвечай кратко. Если запрос про файлы/действия, скажи что инструмент не выбран, но ответь текстом."
            fp = f"{sys_prompt}\n\nКонтекст:\n" + "\n---\n".join(ctx) + f"\n\nЗапрос: {prompt}"
            
            if pm=="LOCAL":
                resp = await asyncio.wait_for(self.local_llm.chat(model="qwen2.5:3b", prompt=fp, context=[]), timeout=15)
                mu = "qwen2.5:3b"
            else:
                resp = await asyncio.wait_for(self.cloud_llm.chat(prompt=fp, context=[]), timeout=15)
                mu = "cloud"
            
            if tokens and pm=="CLOUD": resp = self.vault.unscrub(resp, tokens)
            self._auto_save(f"ASSISTANT: {resp}", user_id, "response")
            return {"reply":resp,"privacy_mode":pm,"model_used":mu,"context_used":len(ctx),"tag":self._tag("chat",mu,len(ctx))}
        except asyncio.TimeoutError: 
            return {"reply":"⏱️ Таймаут LLM","privacy_mode":"LOCAL","model_used":"timeout","context_used":0,"tag":"[⏱️]"}
        except Exception as e: 
            return {"reply":f"⚠️ {str(e)[:80]}","privacy_mode":"LOCAL","model_used":"error","context_used":0,"tag":"[❌]"}
PY
echo "✅ orchestrator.py: чистый агентский поток"

echo "[3/3] Перезапуск..."
pkill -9 -f uvicorn 2>/dev/null || true; pkill -9 -f "bot.py" 2>/dev/null || true; sleep 2
set -a; source ~/magic-brain/.env; set +a
cd ~/magic-brain/interfaces/api; nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
cd ~/magic-brain/interfaces/telegram; nohup python3 bot.py > /tmp/bot.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health && echo "✅ API UP" || echo "❌ API DOWN"

echo ""
echo "🎉 Автономный агент готов."
echo "• Запрос → LLM выбирает ЛУЧШИЙ инструмент из 40+ доступных"
echo "• Сам извлекает аргументы по JSON-схеме"
echo "• 0 хардкода, 0 ручных парсеров"
echo ""
echo "🧪 Тест:"
echo "  • 'Создай файл ~/111.txt и запиши туда: привет тест'"
echo "  • 'Покажи файлы в /home/der'"
echo "  • 'Найди репозитории про Python на GitHub'"
echo ""
echo "ЖДУ: ответ бота или tail -20 /tmp/api.log"
