"""🔄 Agent Loop: Plan → Execute → Context → Replan → Fallback"""
import logging, asyncio, os
from agents.brain.planner import plan, replan
from privacy.local_llm.openrouter_client import OpenRouterClient

class AgentLoop:
    def __init__(self, registry):
        self.registry = registry
        self.max_retries = 2
        self.client = OpenRouterClient(api_key=os.getenv("OPENROUTER_API_KEY"))

    async def run(self, query: str, user_id: int = 1, force_mode: str = None) -> str:
        if force_mode != "tools":
            return await self._chat(query)

        steps = await plan(query, self.registry)
        if not steps:
            logging.info("⚠️ Plan empty → Fallback to chat")
            return await self._chat(query)

        context = []
        for attempt in range(self.max_retries + 1):
            success = True
            for step in steps:
                tool_name = step.get("tool")
                args = step.get("args", {})
                
                if tool_name not in self.registry.skills:
                    logging.warning(f"⚠️ Unknown tool: {tool_name}")
                    success = False; break

                try:
                    func = self.registry.skills[tool_name]["func"]
                    # Передаём ВСЕ аргументы, кроме системных. Python сам разрулит в **kwargs.
                    exclude = {'q', 'ctx', 'uid', 'query', 'context', 'user_id', 'self', 'tn'}
                    tool_args = {k: v for k, v in args.items() if k not in exclude}
                    
                    res = await func(query, context, user_id, **tool_args)
                    res_str = res[:500] if isinstance(res, str) else str(res)
                    context.append({"tool": tool_name, "result": res_str})
                    logging.info(f"✅ {tool_name} OK")
                except Exception as e:
                    logging.error(f"❌ {tool_name} failed: {e}")
                    success = False
                    if attempt < self.max_retries:
                        logging.info(f"🔄 Replan attempt {attempt+1}/{self.max_retries}")
                        steps = await replan(str(e), context, self.registry)
                        if not steps: break
                    else:
                        logging.warning(f"⏭️ Max retries reached for {tool_name}")
                    continue
            if success or not steps: break

        if not context:
            return await self._chat(query)

        summary = "\n".join([f"🛠️ {c['tool']}: {c['result']}" for c in context])
        synthesis = f"Запрос: {query}\nРезультаты:\n{summary}\n\nДай краткий ответ пользователю."
        return await self._chat(synthesis)

    async def _chat(self, prompt: str) -> str:
        try:
            return await self.client.chat(prompt=prompt, context=[])
        except Exception as e:
            logging.error(f"❌ Chat fallback failed: {e}")
            return "⚠️ Ошибка обработки запроса"
