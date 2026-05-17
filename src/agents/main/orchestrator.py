"""🎛️ Orchestrator v2.0: Clean API Gateway for AgentLoop"""

import asyncio
import logging
from datetime import datetime

logger = logging.getLogger(__name__)


class MagicBrain:
    """Orchestrator: API → AgentLoop (v2.0 compatible)"""

    def __init__(self):
        self.registry = None
        self.loop = None
        self._init_lock = asyncio.Lock()

    async def _ensure_ready(self):
        if self.registry is None:
            async with self._init_lock:
                if self.registry is None:
                    from agents.brain.registry import registry

                    await registry.reload()
                    self.registry = registry
                    from agents.brain.agent_loop import AgentLoop

                    self.loop = AgentLoop(registry)
                    logger.info("✅ MagicBrain initialized (v2.0)")

    async def process(self, query: str, user_id: int = 1, force_mode: str = None, **kwargs) -> dict:
        """API entry point: /process"""
        await self._ensure_ready()

        start = datetime.now()
        privacy = "CLOUD"
        model = "agent"
        context_used = 0

        try:
            # 🎯 Прямой вызов AgentLoop с параметрами из запроса
            # force_mode: "tools" | "skills" | None (chat)
            reply = await self.loop.run(query=query, user_id=user_id, force_mode=force_mode)

            # Авто-определение тега
            if "✅" in reply:
                tag = "[🛠️agent]"
            elif "⏱️" in reply:
                tag = "[⏱️timeout]"
            elif "⚠️" in reply:
                tag = "[⚠️error]"
            else:
                tag = "[💬chat]"

            return {
                "reply": reply,
                "privacy_mode": privacy,
                "model_used": model,
                "context_used": context_used,
                "tag": tag,
                "time_ms": (datetime.now() - start).total_seconds() * 1000,
            }

        except Exception as e:
            logger.exception(f"💥 Orchestrator crash: {e}")
            return {
                "reply": f"⚠️ System error: {str(e)[:100]}",
                "privacy_mode": "LOCAL",
                "model_used": "error",
                "context_used": 0,
                "tag": "[❌crash]",
                "time_ms": (datetime.now() - start).total_seconds() * 1000,
            }


# 🔌 Global instance for API
brain = MagicBrain()


# 🔌 Backward compat: module-level run() if someone imports it
async def run(query: str, user_id: int = 1, force_mode: str = None, **kwargs):
    result = await brain.process(query, user_id, force_mode, **kwargs)
    return result.get("reply", "")
