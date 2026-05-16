#!/bin/bash
set -e
cd ~/magic-brain

echo "=== [0] Проверка синтаксиса новых файлов ==="
python3 -m py_compile interfaces/api/main.py && echo "✅ main.py OK" || echo "❌ main.py SYNTAX ERROR"
python3 -m py_compile agents/main/orchestrator.py && echo "✅ orchestrator.py OK" || echo "❌ orchestrator.py SYNTAX ERROR"
python3 -m py_compile agents/brain/tool_router.py && echo "✅ tool_router.py OK" || echo "❌ tool_router.py SYNTAX ERROR"

echo ""
echo "=== [1] Прямой тест tool_router (без API) ==="
python3 << 'PY'
import sys, asyncio, os; sys.path.insert(0, '.'); os.environ.setdefault('QDRANT_HOST','localhost')
from agents.brain.registry import registry
from agents.brain.tool_router import ToolRouter
from privacy.local_llm.ollama_client import OllamaClient

class MockOrch:
    def __init__(self): self.local_llm = OllamaClient()

async def test():
    await registry.wait_ready(timeout=10)
    print(f"📦 Registry: {len(registry.skills)} tools")
    
    query = "Покажи файлы в /home/der"
    tools = registry.list(query)[:5]
    print(f"🔧 Relevant: {tools}")
    
    meta = [{"name":t, "desc":registry.skills[t].get("desc",""), "params":registry.skills[t].get("params",{})} for t in tools if t in registry.skills]
    
    router = ToolRouter(MockOrch())
    decision = await router.select_and_parse(query, meta)
    print(f"🎯 Router decision: {decision}")
    
    # Покажем сырой ответ LLM
    from agents.brain.tool_router import ToolRouter
    t_desc = "\n".join([f"- {t['name']}: {t['desc']}" for t in meta[:3]])
    prompt = f"""STRICT JSON ONLY. NO MARKDOWN.
Tools:
{t_desc}
Query: {query}
Output: {{"tool": "name", "args": {{}}, "conf": 0.9}}"""
    
    raw = await MockOrch().local_llm.chat(model="qwen2.5:3b", prompt=prompt, context=[])
    print(f"🤖 LLM raw response ({len(raw)} chars): {raw[:300]}...")

asyncio.run(test())
PY

echo ""
echo "=== [2] Чистый рестарт API с выводом ошибок ==="
pkill -9 -f "uvicorn.*:8000" 2>/dev/null || true
sleep 2

cd ~/magic-brain/interfaces/api
# Запускаем ВПЕРЕДНЕМ РЕЖИМЕ чтобы видеть ошибки импорта
echo "🚀 Starting API (watch for import errors)..."
timeout 10 python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 2>&1 | head -30 &
API_PID=$!
sleep 5

# Проверка здоровья
if curl -sf --max-time 3 http://127.0.0.1:8000/health >/dev/null; then
    echo "✅ API responding"
else
    echo "❌ API not responding - checking logs:"
    tail -20 /tmp/api.log 2>/dev/null || echo "(no log file)"
fi

echo ""
echo "=== [3] Тест с выводом ВСЕХ логов ==="
curl -s -X POST http://127.0.0.1:8000/process \
  -H "Content-Type: application/json" \
  -d '{"user_id": 999, "text": "Покажи файлы в /home/der", "force_mode": "tools"}' \
  | python3 -m json.tool

echo ""
echo "=== [4] Логи прямо сейчас ==="
tail -50 /tmp/api.log 2>/dev/null | grep -E 'INFO|ERROR|WARN|force|Agent|Router|Registry|Executing|🔧|🎯|⚙️|✅|❌' || echo "(no matching logs)"
