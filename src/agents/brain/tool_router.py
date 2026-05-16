import re, json, logging
from typing import List, Dict, Optional

class FastToolRouter:
    """Автономный выбор инструмента по ключевым словам + извлечение аргументов из схемы"""
    def select(self, query: str, tools: List[Dict]) -> Optional[Dict]:
        q = query.lower()
        best_score, best_tool, best_args = 0, None, {}
        
        for tool in tools:
            tname, tdesc, params = tool["name"], tool.get("desc","").lower(), tool.get("params",{})
            score = 0
            
            # 1. Совпадение по описанию
            for word in re.findall(r'[а-яa-z]{3,}', q):
                if word in tdesc: score += 2
            # 2. Совпадение по имени
            if tname in q: score += 5
            # 3. Контекст пути
            if ("path" in params or "file" in tname) and ("/" in q or "~/" in q or "файл" in q or "каталог" in q or "покажи" in q):
                score += 10
            
            if score > best_score:
                best_score = score
                best_tool = tname
                # Извлекаем аргументы
                args = {}
                for pname, pschema in params.items():
                    if pname == "path":
                        m = re.search(r'(/[a-zA-Z0-9./_~-]+|~/[a-zA-Z0-9./_~-]+)', query)
                        args["path"] = m.group(0) if m else "/home/der"
                    elif pname == "content" or pname == "text":
                        m = re.search(r'(?:напиши туда|запиши|содержимое|текст|скажи)[:\s]*(.+)', query, re.I|re.DOTALL)
                        args["content"] = m.group(1).strip() if m else query
                    elif pname == "query":
                        m = re.search(r'(?:про|о|найти|ищи)\s+(.+)', query, re.I)
                        args["query"] = m.group(1).strip() if m else q
                    else:
                        m = re.search(rf'{pname}[:\s]*([^\s,;]+)', query, re.I)
                        if m: args[pname] = m.group(1)
                best_args = args
        
        if best_score >= 3:
            return {"tool_name": best_tool, "args": best_args}
        return None

tool_router = FastToolRouter()
