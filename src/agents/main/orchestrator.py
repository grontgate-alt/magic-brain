"""🎛️ Orchestrator: Minimal API Gateway → agent_loop.run()"""

import logging
from datetime import datetime

logger = logging.getLogger(__name__)


# 🎯 Глобальная точка входа: просто прокси в agent_loop
async def process(query: str, user_id: int = 1, force_mode: str = None, **kwargs) -> dict:
    """API /process handler: delegates to agent_loop.run()"""
    start = datetime.now()
    try:
        # Импорт внутри функции для отложенной инициализации
        from agents.brain.agent_loop import run as agent_run

        reply = await agent_run(query=query, user_id=user_id, force_mode=force_mode, **kwargs)

        # Формируем ответ в ожидаемом формате
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
        logger.exception(f"💥 process() error: {e}")
        return {
            "reply": f"⚠️ Error: {str(e)[:100]}",
            "privacy_mode": "LOCAL",
            "model_used": "error",
            "context_used": 0,
            "tag": "[❌]",
            "time_ms": (datetime.now() - start).total_seconds() * 1000,
        }
