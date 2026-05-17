import re


class PrivacyRouter:
    def __init__(self):
        # Ключевые слова приватности (для токенизации, не для маршрутизации)
        self.sensitive_keywords = [
            "пароль",
            "password",
            "pwd",
            "секрет",
            "ключ",
            "token",
            "api_key",
            "карта",
            "card",
            "cvv",
            "пин",
            "pin",
            "личное",
            "приват",
            "конфиденциально",
        ]
        # Паттерны для ИЗВЛЕЧЕНИЯ данных (только эти → LOCAL)
        self.retrieval_patterns = [
            r"покажи.*мой",
            r"напомни.*мой",
            r"какой.*мой.*пароль",
            r"что я сохранял",
            r"мой.*пароль.*от",
            r"достань.*из памяти",
            r"покажи.*из.*хранилищ",
            r"верни.*мой.*секрет",
        ]

    def classify(self, query: str) -> str:
        """
        Маршрутизация по интенту:
        - LOCAL: только если запрос явно на извлечение МОИХ сохранённых данных
        - CLOUD: всё остальное (с токенизацией чувствительных паттернов)
        """
        q = query.lower().strip()

        # Проверяем паттерны извлечения (только они → LOCAL)
        for pattern in self.retrieval_patterns:
            if re.search(pattern, q, re.IGNORECASE):
                return "LOCAL"

        # Всё остальное → CLOUD (с токенизацией при необходимости)
        return "CLOUD"

    def needs_scrubbing(self, text: str) -> bool:
        """Всегда возвращаем True для CLOUD-маршрута"""
        return any(kw in text.lower() for kw in self.sensitive_keywords)
