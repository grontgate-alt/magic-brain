class PromptOptimizer:
    TEMPLATES = {
        "default": "Ты — полезный ассистент. Отвечай точно, кратко, по делу. Если не знаешь — скажи.",
        "rag": "Используй предоставленный контекст. Если контекст не релевантен — сообщи. Не выдумывай факты.",
        "code": "Пиши чистый, безопасный код. Добавляй комментарии. Избегай хардкода секретов.",
    }

    def optimize(self, query: str, task_type: str = "default") -> str:
        tpl = self.TEMPLATES.get(task_type, self.TEMPLATES["default"])
        return f"{tpl}\n\nЗапрос пользователя:\n{query}"
