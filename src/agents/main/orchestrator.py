"""🎛️ Orchestrator: MagicBrain class → agent_loop.run()"""

import logging
from datetime import datetime

logger = logging.getLogger(__name__)


class MagicBrain:
    """Minimal orchestrator: delegates to agent_loop.run()"""

    def __init__(self):
        pass

    async def process(self, query: str, user_id: int = 1, force_mode: str = None, **kwargs) -> dict:
        """API handler: calls agent_loop.run()"""
        start = datetime.now()
        try:
            from agents.brain.agent_loop import run as agent_run

            reply = await agent_run(query=query, user_id=user_id, force_mode=force_mode, **kwargs)
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
