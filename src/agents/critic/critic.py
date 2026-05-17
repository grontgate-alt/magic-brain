class Critic:
    def validate(self, response: str) -> tuple[bool, list]:
        # Никогда не блокируем. Только собираем "подозрения" для лога.
        issues = []
        if len(response) > 2000:
            issues.append("long_response")
        if "не могу" in response.lower() and "помочь" in response.lower():
            issues.append("refusal_detected")  # просто лог, не блокировка
        return True, issues  # ✅ всегда OK

    def refine(self, response: str, issues: list) -> str:
        return response  # не меняем ответ
