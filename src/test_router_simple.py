import sys, asyncio, os, json, re
sys.path.insert(0, '.')
os.environ.setdefault('QDRANT_HOST', 'localhost')

from agents.brain.registry import registry
from privacy.local_llm.ollama_client import OllamaClient

async def test():
    print("=== TOOL ROUTER DEBUG ===\n")
    
    # 1. Ждём загрузки
    await registry.wait_ready(timeout=10)
    print(f"1️⃣ Registry: {len(registry.skills)} tools\n")
    
    # 2. Query и релевантные инструменты
    query = "Покажи файлы в /home/der"
    tools = registry.list(query)[:5]
    print(f"2️⃣ Query: {query}")
    print(f"   Relevant tools: {tools}\n")
    
    # 3. Формируем промпт как в tool_router
    meta = [{"name":t, "desc":registry.skills[t].get("desc",""), "params":registry.skills[t].get("params",{})} for t in tools if t in registry.skills]
    t_desc = "\n".join([f"- {t['name']}: {t['desc']} (args: {json.dumps(t.get('params',{}))})" for t in meta])
    
    prompt = f"""STRICT JSON ONLY. NO MARKDOWN. NO TEXT BEFORE OR AFTER.
Available tools:
{t_desc}

User query: {query}

Return format:
{{"tool": "exact_tool_name", "args": {{"param": "value"}}, "conf": 0.9}}
If no match: {{"tool": null}}"""

    print(f"3️⃣ Prompt sent to LLM ({len(prompt)} chars):\n---\n{prompt[:500]}...\n---\n")
    
    # 4. Запрос к LLM
    ollama = OllamaClient()
    print("4️⃣ Calling qwen2.5:3b...")
    try:
        raw = await asyncio.wait_for(ollama.chat(model="qwen2.5:3b", prompt=prompt, context=[]), timeout=20)
        print(f"   Raw response ({len(raw)} chars):\n{raw}\n")
    except Exception as e:
        print(f"   ❌ LLM error: {e}\n")
        return
    
    # 5. Парсинг
    print("5️⃣ Parsing JSON...")
    cleaned = re.sub(r'```[a-z]*\n?|\n?```', '', raw).strip()
    match = re.search(r'\{.*\}', cleaned, re.DOTALL)
    
    if not match:
        print(f"   ❌ No JSON object found in response")
        print(f"   Cleaned: {cleaned[:200]}")
        return
    
    try:
        parsed = json.loads(match.group(0))
        print(f"   ✅ Parsed: {parsed}")
        
        if not parsed.get("tool"):
            print(f"   ⚠️ tool is null/empty → router returns None")
        elif parsed.get("conf", 0) < 0.5:
            print(f"   ⚠️ conf={parsed.get('conf')} < 0.5 → router returns None")
        else:
            print(f"   🎯 Router would select: {parsed['tool']} with args: {parsed.get('args', {})}")
    except json.JSONDecodeError as e:
        print(f"   ❌ JSON decode error: {e}")
        print(f"   Tried to parse: {match.group(0)[:200]}")

asyncio.run(test())
