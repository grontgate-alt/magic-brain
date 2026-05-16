#!/bin/bash
set -e
cd ~/magic-brain

echo "[1/3] Фикс Planner: распознавание путей → приоритет MCP..."
cat << 'PY' > agents/brain/planner.py
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
PY
echo "✅ Planner: приоритет MCP для путей"

echo "[2/3] Фикс Orchestrator: пост-очистка морализма из облака..."
cat << 'PY' >> agents/main/orchestrator.py

def _strip_moralizing(response: str) -> str:
    """Удаляет блоки морализма от облачной модели"""
    # Паттерны для удаления "лекций"
    patterns = [
        r'(?s)(?:###?\s*)?(?:1\.?\s*)?[\*\-]*\s*(?:Нарушение правил|Оскорбления|Недопустимо|Этика|Правила|Важно|Примечание|Обратите внимание)[\s\S]*?(?=\n\n|\Z|###|\d+\.)',
        r'(?s)Я не могу и не должен[\s\S]*?(?=\n\n|\Z|###)',
        r'(?s)Если вы хотите получить полезную информацию[\s\S]*?(?=\n\n|\Z|###)',
        r'(?s)Пожалуйста, переформулируйте[\s\S]*?(?=\n\n|\Z|###)',
    ]
    result = response
    for p in patterns:
        result = re.sub(p, '', result, flags=re.IGNORECASE)
    # Удаляем пустые блоки
    result = re.sub(r'\n{3,}', '\n\n', result).strip()
    return result if result else response
PY

# Вставляем вызов _strip_moralizing перед возвратом ответа
sed -i '/self._auto_save(f"ASSISTANT: {resp}", user_id, "response")/i\        # Очистка морализма если ответ из облака\n        if mode == "CLOUD":\n            resp = _strip_moralizing(resp)' agents/main/orchestrator.py
echo "✅ Orchestrator: очистка морализма"

echo "[3/3] Перезапуск API..."
pkill -f uvicorn 2>/dev/null || true; sleep 3
set -a; source ~/magic-brain/.env; set +a
cd ~/magic-brain/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health && echo "✅ API UP" || echo "❌ API DOWN"

echo ""
echo "🧪 Тест (напиши боту):"
echo "  • 'Покажи файлы в /home/der'"
echo "  • 'Прочитай ~/magic-brain/.env'"
echo ""
echo "Ожидаемый ответ:"
echo "  • der"
echo "  • magic-brain"
echo "  • .bashrc"
echo "     [🔐mcp_filesystem_list_directory]"
echo ""
echo "ЖДУ: результат."
