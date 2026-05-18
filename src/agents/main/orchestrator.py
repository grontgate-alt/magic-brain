"""🎛️ Orchestrator: MagicBrain → agent_loop.run()"""
import logging
from datetime import datetime
logger = logging.getLogger(__name__)

class MagicBrain:
    async def process(self, query: str, user_id: int = 1, force_mode: str = None, force_agent=None, **kwargs) -> dict:
        start = datetime.now()
        try:
            from agents.brain.agent_loop import run as agent_run
            mode = force_mode or ("skills" if force_agent else None)
            reply = await agent_run(query=query, user_id=user_id, force_mode=mode)
            
            tag = "[🛠️agent]" if "✅" in reply else "[⏱️]" if "⏱️" in reply else "[💬]"
            return {
                "reply": reply, "privacy_mode": "CLOUD", "model_used": "agent",
                "context_used": 0, "tag": tag, "time_ms": (datetime.now() - start).total_seconds() * 1000
            }
        except Exception as e:
            logger.exception(f"💥 MagicBrain.process: {e}")
            return {
                "reply": f"⚠️ Error: {str(e)[:100]}", "privacy_mode": "LOCAL",
                "model_used": "error", "context_used": 0, "tag": "[❌]",
                "time_ms": (datetime.now() - start).total_seconds() * 1000
            }

brain = MagicBrain()
