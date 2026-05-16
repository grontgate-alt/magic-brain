from typing import Optional, Dict
from collections import defaultdict
import time

class SessionManager:
    """Хранит предпочтения режима для каждого пользователя"""
    def __init__(self, ttl_seconds: int = 3600):
        self.sessions: Dict[int, dict] = defaultdict(lambda: {
            "mode": "auto",  # auto|chat|tools|rag_direct|web_search
            "last_activity": time.time(),
            "pending_clarification": None,  # если ждём уточнения
        })
        self.ttl = ttl_seconds
    
    def get(self, user_id: int) -> dict:
        session = self.sessions[user_id]
        # TTL cleanup
        if time.time() - session["last_activity"] > self.ttl:
            session["mode"] = "auto"
            session["pending_clarification"] = None
        session["last_activity"] = time.time()
        return session
    
    def set_mode(self, user_id: int, mode: str):
        self.sessions[user_id]["mode"] = mode
        self.sessions[user_id]["pending_clarification"] = None
    
    def set_pending(self, user_id: int, query: str, options: list):
        self.sessions[user_id]["pending_clarification"] = {
            "query": query, "options": options, "created": time.time()
        }
    
    def clear_pending(self, user_id: int):
        self.sessions[user_id]["pending_clarification"] = None
    
    def get_pending(self, user_id: int) -> Optional[dict]:
        pending = self.sessions[user_id]["pending_clarification"]
        if pending and time.time() - pending["created"] > 300:  # 5 мин таймаут
            self.clear_pending(user_id)
            return None
        return pending

session_manager = SessionManager()
