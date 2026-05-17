#!/usr/bin/env python3
import re
import uuid


class SimpleVault:
    def __init__(self):
        self.store = {}

    def scrub(self, text):
        """Заменяет секреты на токены"""
        patterns = [
            (r"(пароль|password|pwd)\s*[=:]\s*(\S+)", "SCRUB_PWD"),
            (r"\b[\w.-]+@[\w.-]+\.\w+\b", "SCRUB_EMAIL"),
            (r"\b\d{10,}\b", "SCRUB_NUM"),
        ]

        res = text
        for pattern, prefix in patterns:
            matches = list(re.finditer(pattern, res, re.IGNORECASE))
            # Идем с конца, чтобы не сбить индексы
            for m in reversed(matches):
                val = m.group(0)
                token = f"[{prefix}_{uuid.uuid4().hex[:6]}]"
                self.store[token] = val
                # Заменяем всё совпадение или только значение?
                # Для теста заменим всё совпадение на токен
                res = res[: m.start()] + token + res[m.end() :]
        return res

    def restore(self, text):
        """Возвращает оригиналы"""
        for token, val in self.store.items():
            text = text.replace(token, val)
        return text


# === ТЕСТЫ ===
v = SimpleVault()

tests = [
    "Мой пароль от почты = SuperSecret123",
    "Email: admin@example.com и код 1234567890",
    "Обычный текст без секретов",
]

print(
    f"{'ТЕСТ':<15} | {'ОРИГИНАЛ':<40} | {'ТОКЕНИЗИРОВАНО':<30} | {'ВОССТАНОВЛЕНО':<40} | {'РЕЗУЛЬТАТ'}"
)
print("-" * 160)

for i, original in enumerate(tests, 1):
    scrubbed = v.scrub(original)
    restored = v.restore(scrubbed)
    ok = "✅ OK" if original == restored else "❌ FAIL"

    # Сокращаем вывод для консоли
    o_short = original[:35] + "..." if len(original) > 35 else original
    s_short = scrubbed[:30] + "..." if len(scrubbed) > 30 else scrubbed
    r_short = restored[:35] + "..." if len(restored) > 35 else restored

    print(f"Test {i:<11} | {o_short:<40} | {s_short:<30} | {r_short:<40} | {ok}")

# Проверка хранилища
print(f"\n Состояние Vault (Store): {v.store}")
