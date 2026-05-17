"""🎛️ Orchestrator: MagicBrain → agent_loop.run() with param mapping"""

import logging
from datetime import datetime

logger = logging.getLogger(__name__)


class MagicBrain:
    """Minimal orchestrator with parameter mapping for agent_loop compat"""

    def __init__(self):
        pass

    async def process(
        self,
        query: str,
        user_id: int = 1,
        force_mode: str = None,
        force_agent: str = None,
        **kwargs,
    ) -> dict:
        """
        API handler: maps force_agent→force_mode, filters kwargs, calls agent_loop.run()
        """
        start = datetime.now()
        try:
            # 🗝️ Маппинг параметров: force_agent (API) → force_mode (agent_loop)
            mode = force_mode or force_agent

            # Фильтруем kwargs: оставляем только то, что принимает agent_loop.run()
            # (query, user_id, force_mode, registry) — остальное отбрасываем
            safe_kwargs = {k: v for k, v in kwargs.items() if k in ("registry",)}

            from agents.brain.agent_loop import run as agent_run

            reply = await agent_run(query=query, user_id=user_id, force_mode=mode, **safe_kwargs)

            tag = "[🛠️agent]" if "✅" in reply else "[⏱️]" if "⏱️" in reply else "[💬]"
            return {
                "reply": reply,
                "privacy_mode": "CLOUD",
                "model_used": "agent",
                "context_used": 0,
                "tag": tag,
                "time_ms": (datetime.now() - start).total_seconds() * 1000,
            }
        except Exception as e:
            logger.exception(f"💥 MagicBrain.process: {e}")
            return {
                "reply": f"⚠️ Error: {str(e)[:100]}",
                "privacy_mode": "LOCAL",
                "model_used": "error",
                "context_used": 0,
                "tag": "[❌]",
                "time_ms": (datetime.now() - start).total_seconds() * 1000,
            }


# Global instance for main.py
brain = MagicBrain()
