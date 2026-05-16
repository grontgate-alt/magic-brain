import re
from typing import Literal, Tuple

Intent = Literal["chat", "tools", "rag_direct", "web_search", "unknown"]

class IntentRouter:
    """Определяет интент запроса с оценкой уверенности"""
    
    # Паттерны с весами уверенности (0.0-1.0)
    PATTERNS = {
        "tools": [
            (r'(/[\w./~-]+|~/[\w./~-]+)', 0.95),  # путь → файлы
            (r'покажи.*файл|прочитай.*файл|открой.*файл|сохрани.*файл', 0.9),
            (r'список.*файлов|каталог|ls|dir|файлы в', 0.85),
            (r'github.*репозиторий|поиск.*репозиторий|repo|pull request', 0.9),
            (r'посчитай|вычисли|калькулятор|\d+[\s]*[\*\+\-/]', 0.8),
            (r'веб|поиск.*интернет|найди.*в интернете|гугл', 0.85),
        ],
        "rag_direct": [
            (r'покажи.*мой|напомни.*мой|что я сохранял|мой пароль|моя карта|мой телефон', 0.95),
            (r'достань.*из памяти|верни.*из хранилища|найди.*в памяти', 0.9),
        ],
        "web_search": [
            (r'найди.*в интернете|поиск.*веб|гугл.*про|новости.*про|статья.*про', 0.85),
        ],
        "chat": [
            (r'привет|как дела|что нового|расскажи|объясни|помоги', 0.7),
        ],
    }
    
    def classify(self, query: str) -> Tuple[Intent, float, str]:
        """
        Возвращает: (интент, уверенность, причина)
        """
        q = query.lower().strip()
        scores: dict[str, float] = {}
        reasons: dict[str, str] = {}
        
        for intent, patterns in self.PATTERNS.items():
            for pattern, weight in patterns:
                if re.search(pattern, q, re.I):
                    if intent not in scores or weight > scores[intent]:
                        scores[intent] = weight
                        reasons[intent] = pattern
        
        if not scores:
            return "chat", 0.5, "default"  # дефолт: чат
        
        # Выбираем лучший
        best_intent = max(scores, key=scores.get)
        confidence = scores[best_intent]
        reason = reasons[best_intent]
        
        # Эвристика: если есть "мой" + "пароль/память" → точно rag_direct
        if "мой" in q and any(k in q for k in ["пароль", "память", "сохранил", "запомнил"]):
            return "rag_direct", 0.99, "personal_data_keyword"
        
        return best_intent, confidence, reason
    
    def needs_clarification(self, intent: Intent, confidence: float, query: str) -> bool:
        """Нужно ли уточнить у пользователя?"""
        if confidence >= 0.9:
            return False
        if intent == "chat":
            return False  # чат всегда безопасен
        if confidence < 0.7:
            return True
        # Пограничные случаи
        if intent == "tools" and "покажи" in query.lower():
            # "покажи" может быть и про файлы, и про память
            return confidence < 0.85
        return False
    
    def get_clarification_options(self, query: str) -> list[dict]:
        """Возвращает варианты для уточнения"""
        return [
            {"label": "🗄️ Найти в памяти", "intent": "rag_direct", "payload": query},
            {"label": "🛠️ Выполнить действие", "intent": "tools", "payload": query},
            {"label": "💬 Просто ответить", "intent": "chat", "payload": query},
        ]

intent_router = IntentRouter()
