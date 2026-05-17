import os
import sys
from pathlib import Path

import httpx

BASE = Path(__file__).parent.parent.parent
if str(BASE) not in sys.path:
    sys.path.insert(0, str(BASE))


class OllamaClient:
    def __init__(self, host: str = os.getenv("OLLAMA_HOST", "http://localhost:11434")):
        self.host = host

    async def chat(self, model: str, prompt: str, context: list[str] = None) -> str:
        ctx = "\n\nКонтекст из базы:\n" + "\n---\n".join(context) if context else ""
        async with httpx.AsyncClient(timeout=120) as c:
            r = await c.post(
                f"{self.host}/api/generate",
                json={"model": model, "prompt": ctx + "\n\n" + prompt, "stream": False},
            )
            return r.json().get("response", "⚠️ Нет ответа от локальной модели")
