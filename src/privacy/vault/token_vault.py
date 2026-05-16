import re, uuid

class TokenVault:
    """Токенизатор с поддержкой кириллицы в паролях"""
    def __init__(self):
        pass
    
    def scrub(self, text: str) -> tuple[str, dict]:
        tokens = {}
        patterns = [
            (r'[\w.-]+@[\w.-]+\.\w+', 'EMAIL'),
            (r'\+?7?\s?\(?\d{3}\)?\s?\d{3}[-\s]?\d{2}[-\s]?\d{2}', 'PHONE'),
            (r'\b\d{8,}\b', 'NUMBER'),
            # ✅ Пароль: ключевое слово + значение (с поддержкой кириллицы!)
            (r'(пароль|password|pwd|секрет|pass)\s*[=:]\s*([^\s,;.!?\n]{4,})', 'SECRET'),
            # ✅ Отдельные "сложные" значения (6+ символов, смесь букв/цифр)
            (r'(?<![\w@])([A-Za-z0-9а-яА-ЯёЁ]{6,})(?![\w@.])', 'SECRET'),
        ]
        
        result = text
        for pattern, tag in patterns:
            matches = list(re.finditer(pattern, result, re.IGNORECASE))
            for m in reversed(matches):
                orig = m.group(0)
                # Для SECRET с группами берём только значение (группа 2)
                if tag == 'SECRET' and m.lastindex and m.lastindex >= 2:
                    orig = m.group(2)
                    # Пересчитываем позиции для замены только значения
                    start, end = m.start(2), m.end(2)
                else:
                    start, end = m.start(), m.end()
                
                token = f"[__SCRUB_{tag}_{uuid.uuid4().hex[:8]}__]"
                tokens[token] = orig
                result = result[:start] + token + result[end:]
        
        return result, tokens
    
    def unscrub(self, text: str, tokens: dict) -> str:
        for token, orig in tokens.items():
            text = text.replace(token, orig)
        return text
