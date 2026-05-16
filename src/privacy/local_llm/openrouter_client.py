import os, httpx, json

class OpenRouterClient:
    def __init__(self, api_key: str = None, router=None):
        self.api_key = api_key or os.getenv("OPENROUTER_API_KEY", "")
        self.router = router
        self.base_url = "https://openrouter.ai/api/v1"
        self.model = "openrouter/free"

    async def chat(self, prompt: str, context: list = None, preserve_tokens: bool = True) -> str:
        if not self.api_key or len(self.api_key) < 20:
            return "⚠️ OpenRouter ключ не задан"
        
        ctx = "\n".join(context) if context else ""
        
        # === КЛЮЧЕВАЯ ИНСТРУКЦИЯ: сохранять токены ===
        token_instruction = ""
        if preserve_tokens and "[__SCRUB_" in prompt:
            token_instruction = "\n\n❗ ВАЖНО: В запросе есть токены вида [__SCRUB_*__]. НЕ заменяй их на другие значения. Просто скопируй их в ответ как есть, без изменений."
        
        messages = [{"role": "system", "content": f"Отвечай подробно и полезно.{token_instruction}"}]
        if ctx: messages.append({"role": "system", "content": f"Контекст:\n{ctx}"})
        messages.append({"role": "user", "content": prompt})
        
        try:
            async with httpx.AsyncClient(timeout=60) as c:
                r = await c.post(
                    f"{self.base_url}/chat/completions",
                    headers={
                        "Authorization": f"Bearer {self.api_key}",
                        "HTTP-Referer": "http://localhost",
                        "X-Title": "MagicBrain",
                        "Content-Type": "application/json"
                    },
                    json={"model": self.model, "messages": messages, "max_tokens": 2048, "temperature": 0.7}
                )
                if r.status_code == 200:
                    d = r.json()
                    return d.get("choices",[{}])[0].get("message",{}).get("content","").strip()
                else:
                    return f"⚠️ OpenRouter {r.status_code}: {r.text[:150]}"
        except Exception as e:
            return f"⚠️ OpenRouter ошибка: {type(e).__name__}: {str(e)[:100]}"
