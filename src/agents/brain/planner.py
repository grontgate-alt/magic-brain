"""🧭 Planner v2.3: Strict JSON + Chaining Logic"""
import asyncio
import json
import logging
import re
from typing import List, Dict

logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """You are an AI tool planner. Return ONLY a valid JSON array of tool steps.
Tools: "web_search", "write_file", "read_file", "execute_bash".
RULES:
1. If user asks to find info and create a file -> Use "web_search" then "write_file".
2. In the second step, use the output of the first step via Jinja: "{{step_0_result}}".
3. NEVER output markdown or explanations. ONLY JSON.
Example: [{"tool": "web_search", "args": {"query": "Pushkin poem text"}}, {"tool": "write_file", "args": {"path": "/tmp/poem.txt", "content": "{{step_0_result}}"}}]"""

async def plan(query: str, registry) -> List[Dict]:
    from privacy.local_llm.openrouter_client import OpenRouterClient
    client = OpenRouterClient(api_key=__import__('os').getenv("OPENROUTER_API_KEY"))
    if not client: return []

    prompt = f"{SYSTEM_PROMPT}
User Task: {query}
JSON:"
    try:
        resp = await client.chat(prompt=prompt, temperature=0.0)
        match = re.search(r'\[.*\]', resp, re.DOTALL)
        if not match: return []
        
        result = json.loads(match.group())
        known_tools = registry.skills.keys()
        return [step for step in result if isinstance(step, dict) and step.get("tool") in known_tools]
    except Exception as e:
        logger.error(f"💥 Planner failed: {e}")
        return []

async def replan(error, ctx, reg):
    return []
