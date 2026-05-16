import re
from typing import List, Dict

class Planner:
    STEP_PATTERN = r'(?i)(сначала|потом|затем|далее|шаг|этап|1\.|2\.|\d+\.)'
    
    # === КЛЮЧЕВОЕ: паттерны для прямого вызова MCP ===
    MCP_PATTERNS = {
        r'(/[\w./~-]+|~/[\w./~-]+)': "filesystem",  # любой путь
        r'покажи.*файл|прочитай.*файл|открой.*файл': "filesystem_read",
        r'покажи.*каталог|список.*файлов|ls|dir': "filesystem_list",
        r'github.*репозиторий|поиск.*репозиторий|repo': "github_search",
        r'создай.*файл|запиши.*файл|сохрани.*файл': "filesystem_write",
    }
    
    def decompose(self, query: str, available_skills: List[str]) -> List[Dict]:
        q = query.lower()
        
        # === ПРИОРИТЕТ 1: прямой путь → filesystem MCP ===
        path_match = re.search(r'(/[\w./~-]+|~/[\w./~-]+)', q)
        if path_match:
            path = path_match.group(0)
            # Определяем действие по контексту
            if any(kw in q for kw in ["прочитай", "открой", "покажи содержимое", "читать"]):
                skill = "mcp_filesystem_read_text_file"
            elif any(kw in q for kw in ["список", "каталог", "ls", "dir", "файлы в"]):
                skill = "mcp_filesystem_list_directory"
            elif any(kw in q for kw in ["создай", "запиши", "сохрани"]):
                skill = "mcp_filesystem_write_file"
            else:
                # Дефолт: список если путь без явного действия
                skill = "mcp_filesystem_list_directory"
            
            if skill in available_skills:
                return [{"desc": query, "skill": skill, "path": path, "direct": True}]
        
        # === ПРИОРИТЕТ 2: ключевые слова → выбор скилла ===
        for pattern, action in self.MCP_PATTERNS.items():
            if re.search(pattern, q, re.I):
                # Маппинг действия на конкретный скилл
                skill_map = {
                    "filesystem_read": "mcp_filesystem_read_text_file",
                    "filesystem_list": "mcp_filesystem_list_directory", 
                    "filesystem_write": "mcp_filesystem_write_file",
                    "github_search": "mcp_github_search_repositories",
                    "filesystem": "mcp_filesystem_list_directory"
                }
                skill = skill_map.get(action)
                if skill and skill in available_skills:
                    return [{"desc": query, "skill": skill, "direct": True}]
        
        # === FALLBACK: обычный план ===
        steps = []
        matched_skill = None
        actions = {
            r'напиши|создай|сгенерируй|текст': "text_generator",
            r'поиск|найди|гугл|раг': "rag_search",
            r'сохрани|запомни|запиши': "memory_save",
            r'покажи|достань|верни|напомни': "memory_recall",
            r'посчитай|вычисли|калькулятор': "calculator",
        }
        for pattern, skill in actions.items():
            if re.search(pattern, q):
                matched_skill = skill
                break
        
        if re.search(self.STEP_PATTERN, query):
            parts = re.split(self.STEP_PATTERN, query)
            current = {"desc": "", "skill": matched_skill, "depends_on": None}
            for part in parts:
                part = part.strip()
                if not part: continue
                if re.match(self.STEP_PATTERN, part, re.I):
                    if current["desc"]: steps.append(current)
                    current = {"desc": "", "skill": matched_skill, "depends_on": len(steps)}
                else:
                    current["desc"] += " " + part
            if current["desc"]: steps.append(current)
        else:
            steps.append({"desc": query, "skill": matched_skill, "depends_on": None})
        
        return [s for s in steps if not s["skill"] or s["skill"] in available_skills]
    
    def estimate_complexity(self, query: str) -> str:
        q = query.lower()
        if len(q.split()) < 10 and not any(x in q for x in ["и", "потом", "затем", "сначала"]):
            return "simple"
        elif len(q.split()) < 30:
            return "medium"
        return "complex"
