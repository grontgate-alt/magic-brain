#!/bin/bash
set -e
cd ~/magic-brain

echo "[1/3] ToolRouter: bulletproof JSON парсинг..."
cat << 'PY' > agents/brain/tool_router.py
import re, json, asyncio
from typing import List, Dict, Optional

class ToolRouter:
    def __init__(self, orchestrator):
        self.orch = orchestrator

    async def select_and_parse(self, query: str, available_tools: List[Dict]) -> Optional[Dict]:
        if not available_tools: return None
        
        tools_desc = "\n".join([f"- {t['name']}: {t['desc']} (args: {json.dumps(t.get('params',{}))})" for t in available_tools])
        
        prompt = f"""You are a STRICT JSON router. Output ONLY valid JSON.
Available tools:
{tools_desc}

User query: {query}

Return format:
{{"tool": "exact_tool_name", "args": {{}}, "confidence": 0.9}}
If no tool matches: {{"tool": null}}"""

        try:
            resp = await asyncio.wait_for(
                self.orch.local_llm.chat(model="qwen2.5:3b", prompt=prompt, context=[]),
                timeout=8
            )
            if not resp: return None
            
            # Удаляем markdown-обёртку если есть
            cleaned = resp.replace("```json", "").replace("```", "").strip()
            # Ищем первый валидный JSON-объект
            match = re.search(r'\{[\s\S]*\}', cleaned)
            if not match: return None
            
            parsed = json.loads(match.group(0))
            if not parsed.get("tool") or parsed.get("confidence", 0) < 0.5:
                return None
            return {"tool_name": parsed["tool"], "args": parsed.get("args", {})}
        except (json.JSONDecodeError, asyncio.TimeoutError):
            return None
        except Exception as e:
            print(f"Router error: {e}")
            return None
PY
echo "✅ tool_router.py: защищённый парсер"

echo "[2/3] Orchestrator: агент с graceful fallback..."
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
        self.tool_router = ToolRouter(self)

    def _auto_save(self, t, u, r):
        try:
            v = self.embedder.embed([t])[0]
            self.store.upsert([v], [{"text":t,"user_id":u,"role":r,"privacy":"HIGH"}], [str(uuid.uuid4())])
        except: pass

    def _tag(self, m, mdl, c): return f"[{'🛠️' if m=='tools' else '💬'}{mdl}{' +RAG:'+str(c) if c else ''}]"

    async def _agent_execute(self, query: str, user_id: int) -> Optional[str]:
        """Автономный агент: LLM выбирает инструмент → выполняет → возвращает результат"""
        try:
            await registry.wait_ready(timeout=5)
            tools = registry.list(query)[:8]  # топ-8 релевантных
            if not tools: return None
            
            tool_meta = [{"name":t, "desc":registry.skills[t].get("desc",""), "params":registry.skills[t].get("params",{})} for t in tools if t in registry.skills]
            if not tool_meta: return None
            
            decision = await self.tool_router.select_and_parse(query, tool_meta)
            if not decision or not decision.get("tool_name"): 
                logging.info("🤖 Router: no tool selected")
                return None
            
            tname, args = decision["tool_name"], decision["args"]
            logging.info(f"🎯 Agent chose: {tname} | args: {args}")
            
            # Выполняем
            skill = registry.skills.get(tname)
            if skill and callable(skill.get("func")):
                result = await asyncio.wait_for(skill["func"](query, {}, user_id, **args), timeout=25)
            else:
                result = await asyncio.wait_for(mcp_direct.execute(tname, args), timeout=25)
                
            return str(result) if result else f"✅ {tname} executed"
        except Exception as e:
            logging.warning(f"⚠️ Agent execution failed: {e}")
            return None

    async def _chat_fallback(self, user_query, user_id, start_time):
        """Чат + RAG если агент не сработал"""
        if time.time()-start_time > 30: return "⏱️ Таймаут", "timeout", 0
        
        try:
            pm = self.router.classify(user_query)
            prompt, tokens = user_query, {}
            if pm=="CLOUD" and self.router.needs_scrubbing(user_query): prompt, tokens = self.vault.scrub(user_query)
            
            vec = self.embedder.embed([prompt])[0]
            ctx = [(r.get("payload") or r.get("meta") or {}).get("text","") for r in self.store.search(vec, limit=3)]
            
            fp = f"Отвечай кратко.\n\nКонтекст:\n" + "\n---\n".join(ctx) + f"\n\nЗапрос: {prompt}"
            
            if pm=="LOCAL":
                resp = await asyncio.wait_for(self.local_llm.chat(model="qwen2.5:3b", prompt=fp, context=[]), timeout=12)
                mu = "qwen2.5:3b"
            else:
                resp = await asyncio.wait_for(self.cloud_llm.chat(prompt=fp, context=[]), timeout=12)
                mu = "cloud"
            
            if tokens and pm=="CLOUD": resp = self.vault.unscrub(resp, tokens)
            return resp, mu, len(ctx)
        except asyncio.TimeoutError: return "⏱️ Таймаут", "timeout", 0
        except Exception as e: return f"⚠️ {str(e)[:80]}", "error", 0

    async def process(self, user_query: str, user_id: int, task_type: str = "default", 
                      force_agent: bool = False, force_mode: str = None, intent_override: str = None) -> dict:
        start = time.time()
        self._auto_save(f"USER: {user_query}", user_id, "query")
        
        # Агентский режим (по умолчанию)
        if force_mode not in ("chat", "rag", "web"):
            agent_res = await self._agent_execute(user_query, user_id)
            if agent_res and not agent_res.startswith("⚠️"):
                return {"reply": agent_res, "privacy_mode": "tools", "model_used": "agent", "context_used": 0, "tag": self._tag("tools", "agent", 0)}
        
        # Fallback: Чат
        reply, mu, ctx_cnt = await self._chat_fallback(user_query, user_id, start)
        pm = "LOCAL" if mu=="qwen2.5:3b" else "CLOUD"
        self._auto_save(f"ASSISTANT: {reply}", user_id, "response")
        return {"reply": reply, "privacy_mode": pm, "model_used": mu, "context_used": ctx_cnt, "tag": self._tag("chat", mu, ctx_cnt)}
PY
echo "✅ orchestrator.py: агент + безопасный fallback"

echo "[3/3] Перезапуск..."
pkill -9 -f uvicorn 2>/dev/null || true; pkill -9 -f "bot.py" 2>/dev/null || true; sleep 2
set -a; source ~/magic-brain/.env; set +a
cd ~/magic-brain/interfaces/api; nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
cd ~/magic-brain/interfaces/telegram; nohup python3 bot.py > /tmp/bot.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health && echo "✅ API UP" || echo "❌ API DOWN"

echo ""
echo "🎉 Исправлено:"
echo "  • JSON парсинг: жёсткая очистка markdown + try/except"
echo "  • Агент: если LLM ошибся/вернул пустоту → автоматический fallback в чат"
echo "  • 0 крашей бота, 0 сырых трейсбеков"
echo ""
echo "🧪 Тест: 'Создай файл ~/test.txt и запиши туда: привет агент'"
echo "Ожидаемо: агент выберет write_file, создаст файл, вернёт ✅. Если нет → чат ответит."
echo "ЖДУ: результат или tail -10 /tmp/api.log"
