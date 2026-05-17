"""
🎯 Hybrid Tool Router — быстрый + точный выбор инструмента
1. Keyword match (мгновенно)
2. Semantic similarity (векторный поиск по описаниям)
3. LLM fallback (только если не определилось)
"""

import logging
import re


class HybridToolRouter:
    def __init__(self, embedder=None):
        self.embedder = embedder  # опционально: для семантического поиска
        self.tool_cache = {}  # кэш: запрос → лучший инструмент

    def select(self, query: str, available_tools: list[dict]) -> dict | None:
        """Главный метод: выбирает инструмент или None"""
        q = query.lower().strip()

        # === УРОВЕНЬ 1: Быстрые ключевые слова (90% случаев) ===
        keyword_match = self._keyword_route(q, available_tools)
        if keyword_match:
            logging.info(f"🔑 Keyword match: {keyword_match['tool_name']}")
            return keyword_match

        # === УРОВЕНЬ 2: Семантический поиск (если есть embedder) ===
        if self.embedder and len(available_tools) > 5:
            semantic_match = self._semantic_route(q, available_tools)
            if semantic_match and semantic_match.get("score", 0) > 0.7:
                logging.info(
                    f"🧠 Semantic match: {semantic_match['tool_name']} ({semantic_match['score']:.2f})"
                )
                return semantic_match

        # === УРОВЕНЬ 3: LLM fallback (только если не определилось) ===
        # Здесь можно вызвать локальную модель для сложного выбора
        # Но для скорости пока пропускаем — лучше честный None, чем долгий ответ
        logging.info(f"⚠️ No tool matched for: {q[:50]}")
        return None

    def _keyword_route(self, q: str, tools: list[dict]) -> dict | None:
        """Быстрый поиск по ключевым словам в описании и имени"""
        # Предварительно скомпилированные паттерны для скорости
        patterns = {
            r"файл|каталог|папка|директория|список|ls|dir": ["filesystem"],
            r"git|commit|push|pull|branch|репозиторий": ["git"],
            r"github|pr|issue|repo": ["github"],
            r"ssh|server|vps|deploy|установи|разверни": ["ssh", "devops"],
            r"vpn|amnezia|wireguard|xray|протокол": ["vpn", "devops"],
            r"почта|email|письмо|отправь на": ["email"],
            r"скан|nmap|порт|уязвим|пентест": ["pentest", "security"],
            r"код|python|lint|test|build|docker": ["coding", "devops"],
            r"поиск|найти|гугл|веб|url|http": ["web", "fetch"],
            r"база|sql|postgres|query|данные": ["database"],
        }

        best_score, best_tool = 0, None

        for tool in tools:
            name = tool["name"].lower()
            desc = tool.get("desc", "").lower()
            category = name.split("_")[0] if "_" in name else ""

            score = 0

            # Точное совпадение имени
            if any(kw in name for kw in q.split()):
                score += 10

            # Совпадение по описанию
            for kw in q.split():
                if len(kw) > 3 and (kw in desc or kw in name):
                    score += 2

            # Паттерны категорий
            for pattern, categories in patterns.items():
                if re.search(pattern, q) and any(cat in category for cat in categories):
                    score += 5

            # Параметры: если в запросе есть путь/хост/порт — приоритет инструментам с такими параметрами
            tool_params = tool.get("params", {})
            if ("/" in q or "~/" in q) and "path" in tool_params:
                score += 3
            if re.search(r"\d+\.\d+\.\d+\.\d+", q) and "host" in tool_params:
                score += 3

            if score > best_score and score >= 3:
                best_score = score
                best_tool = tool

        if best_tool:
            return {
                "tool_name": best_tool["name"],
                "args": self._extract_args(q, best_tool),
                "score": best_score,
            }
        return None

    def _semantic_route(self, q: str, tools: list[dict]) -> dict | None:
        """Векторный поиск по описаниям (если есть embedder)"""
        # Реализация при наличии модели эмбеддингов
        # Пока заглушка — можно добавить позже
        return None

    def _extract_args(self, query: str, tool: dict) -> dict:
        """Извлекает аргументы из запроса по схеме инструмента"""
        args = {}
        params = tool.get("params", {})

        for param_name, param_schema in params.items():
            # Путь: /home/der, ~/file.txt
            if param_name in ["path", "file", "directory"] and param_schema.get("type") == "string":
                match = re.search(r"(/[a-zA-Z0-9./_~-]+|~/[a-zA-Z0-9./_~-]+)", query)
                if match:
                    args[param_name] = match.group(0)

            # Хост: 192.168.1.1, example.com
            if (
                param_name in ["host", "server_ip", "target"]
                and param_schema.get("type") == "string"
            ):
                match = re.search(r"(\d{1,3}(?:\.\d{1,3}){3}|[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})", query)
                if match:
                    args[param_name] = match.group(0)

            # Порт: :8080, порт 443
            if param_name in ["port"] and param_schema.get("type") == "integer":
                match = re.search(r":?(\d{2,5})\b", query)
                if match and 1 <= int(match.group(1)) <= 65535:
                    args[param_name] = int(match.group(1))

            # Email
            if param_name in ["email", "to"] and param_schema.get("type") == "string":
                match = re.search(r"([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})", query)
                if match:
                    args[param_name] = match.group(0)

            # Протоколы: ["awg2", "xray"]
            if param_name == "protocols" and param_schema.get("type") == "array":
                found = re.findall(r"\b(awg2|xray|openvpn|wireguard|socks5)\b", query.lower())
                if found:
                    args[param_name] = list(set(found))

        return args


# Экземпляр для импорта
tool_router = HybridToolRouter()
