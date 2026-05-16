#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain
cd $BASE

echo "[1/8] Создаём структуру агентов..."
mkdir -p agents/brain agents/tools

echo "[2/8] Registry: динамическая загрузка скилов..."
cat << 'PY' > agents/brain/registry.py
import importlib, pkgutil, inspect, os
from pathlib import Path

class SkillRegistry:
    """Динамический реестр инструментов/скилов"""
    def __init__(self):
        self.skills = {}
        self._load_from_dir()
    
    def _load_from_dir(self):
        tools_dir = Path(__file__).parent.parent / "tools"
        if not tools_dir.exists(): return
        
        for file in tools_dir.glob("*.py"):
            if file.name.startswith("_"): continue
            module_name = f"agents.tools.{file.stem}"
            try:
                module = importlib.import_module(module_name)
                for name, obj in inspect.getmembers(module):
                    if callable(obj) and hasattr(obj, "__skill__"):
                        meta = obj.__skill__
                        self.skills[meta.get("name", name)] = {
                            "func": obj,
                            "desc": meta.get("desc", ""),
                            "params": meta.get("params", {}),
                            "privacy": meta.get("privacy", "CLOUD")
                        }
            except Exception as e:
                print(f"⚠️ Не загрузил скилл {file.name}: {e}")
    
    def get(self, name: str):
        return self.skills.get(name)
    
    def list_available(self, query: str = None) -> list:
        """Возвращает список скилов, релевантных запросу"""
        if not query:
            return list(self.skills.keys())
        q = query.lower()
        relevant = []
        for name, meta in self.skills.items():
            if name in q or meta.get("desc", "").lower() in q:
                relevant.append(name)
        return relevant if relevant else list(self.skills.keys())[:5]
    
    def reload(self):
        self.skills.clear()
        self._load_from_dir()

registry = SkillRegistry()
PY
echo "✅ registry.py"

echo "[3/8] Planner: декомпозиция запроса на шаги..."
cat << 'PY' > agents/brain/planner.py
import re, json
from typing import List, Dict

class Planner:
    """Разбивает сложный запрос на исполняемые шаги"""
    
    STEP_PATTERN = r'(?i)(сначала|потом|затем|далее|шаг|этап|1\.|2\.|\d+\.)'
    
    def decompose(self, query: str, available_skills: List[str]) -> List[Dict]:
        """Возвращает план: список шагов с целевым скиллом"""
        steps = []
        
        # Простая эвристика: ищем ключевые действия
        actions = {
            r'напиши|создай|сгенерируй|текст': {"skill": "text_generator", "action": "generate"},
            r'поиск|найди|гугл|раг': {"skill": "rag_search", "action": "search"},
            r'сохрани|запомни|запиши': {"skill": "memory_save", "action": "save"},
            r'покажи|достань|верни|напомни': {"skill": "memory_recall", "action": "recall"},
            r'посчитай|вычисли|калькулятор': {"skill": "calculator", "action": "calc"},
            r'код|программа|скрипт|python': {"skill": "code_executor", "action": "execute"},
            r'веб|сайт|url|http': {"skill": "web_fetch", "action": "fetch"},
        }
        
        q = query.lower()
        
        # Определяем основной скилл
        matched_skill = None
        for pattern, meta in actions.items():
            if re.search(pattern, q):
                matched_skill = meta["skill"]
                break
        
        # Если нашли явные шаги (1. 2. 3. или "сначала... потом...")
        if re.search(self.STEP_PATTERN, query):
            parts = re.split(self.STEP_PATTERN, query)
            current_step = {"desc": "", "skill": None, "depends_on": None}
            for part in parts:
                part = part.strip()
                if not part: continue
                if re.match(self.STEP_PATTERN, part, re.I):
                    if current_step["desc"]:
                        steps.append(current_step)
                    current_step = {"desc": "", "skill": matched_skill, "depends_on": len(steps)}
                else:
                    current_step["desc"] += " " + part
            if current_step["desc"]:
                steps.append(current_step)
        else:
            # Один шаг
            steps.append({
                "desc": query,
                "skill": matched_skill,
                "depends_on": None
            })
        
        # Фильтруем по доступным скиллам
        for step in steps:
            if step["skill"] and step["skill"] not in available_skills:
                step["skill"] = None  # fallback на общий обработчик
        
        return steps
    
    def estimate_complexity(self, query: str) -> str:
        """simple | medium | complex"""
        q = query.lower()
        if len(q.split()) < 10 and not any(x in q for x in ["и", "потом", "затем", "сначала"]):
            return "simple"
        elif len(q.split()) < 30:
            return "medium"
        return "complex"
PY
echo "✅ planner.py"

echo "[4/8] Worker: выполнение шага с контекстом..."
cat << 'PY' > agents/brain/worker.py
import asyncio, time
from typing import Optional, Dict, Any

class Worker:
    """Исполняет отдельный шаг плана"""
    
    def __init__(self, orchestrator):
        self.orch = orchestrator
        self.timeout = 60  # секунд на шаг
    
    async def execute(self, step: Dict, context: Dict, user_id: int) -> Dict[str, Any]:
        """Выполняет шаг, возвращает результат + метаданные"""
        start = time.time()
        skill_name = step.get("skill")
        desc = step.get("desc", "")
        
        try:
            # Если есть конкретный скилл — используем его
            if skill_name:
                skill = self.orch.registry.get(skill_name)
                if skill and callable(skill["func"]):
                    # Готовим аргументы
                    args = {"query": desc, "context": context, "user_id": user_id}
                    # Вызов с таймаутом
                    result = await asyncio.wait_for(
                        skill["func"](**args),
                        timeout=self.timeout
                    )
                    return {
                        "success": True,
                        "result": result,
                        "skill_used": skill_name,
                        "duration": time.time() - start,
                        "error": None
                    }
            
            # Fallback: общий обработчик через LLM
            result = await self._fallback_llm(desc, context, user_id)
            return {
                "success": True,
                "result": result,
                "skill_used": "fallback_llm",
                "duration": time.time() - start,
                "error": None
            }
            
        except asyncio.TimeoutError:
            return {"success": False, "result": None, "error": f"timeout>{self.timeout}s", "duration": time.time() - start}
        except Exception as e:
            return {"success": False, "result": None, "error": str(e)[:200], "duration": time.time() - start}
    
    async def _fallback_llm(self, desc: str, context: Dict, user_id: int) -> str:
        """Общий обработчик через LLM если скилл не найден"""
        # Используем существующий процесс из orchestrator
        # (в реальности здесь будет отдельный вызов с минимальным контекстом)
        ctx_text = "\n".join(context.get("rag_results", [])[:3]) if context else ""
        prompt = f"Контекст:\n{ctx_text}\n\nЗадача: {desc}\n\nОтвет:"
        
        # Вызов локальной модели для скорости
        if hasattr(self.orch, 'local_llm'):
            return await self.orch.local_llm.chat(model="qwen2.5:3b", prompt=prompt, context=[])
        return f"[Выполнено: {desc[:50]}...]"
PY
echo "✅ worker.py"

echo "[5/8] Critic: валидация и авто-ретрай..."
cat << 'PY' > agents/brain/critic_loop.py
import re
from typing import Tuple, List

class CriticLoop:
    """Проверяет результат и при необходимости запускает ретрай"""
    
    MAX_RETRIES = 2
    CRITICAL_PATTERNS = [
        r'не могу|cannot|не удалось|error|ошибка',
        r'пусто|нет данных|nothing found',
        r'слишком длинный|too long|превышен',
    ]
    
    def validate(self, result: str, step_desc: str) -> Tuple[bool, List[str]]:
        """Возвращает (ок, список проблем)"""
        issues = []
        r = result.lower() if result else ""
        
        # Проверка на отказ/ошибку
        for pattern in self.CRITICAL_PATTERNS:
            if re.search(pattern, r, re.I):
                issues.append(f"refusal_or_error: {pattern}")
        
        # Проверка на пустой ответ
        if not result or len(result.strip()) < 10:
            issues.append("empty_response")
        
        # Проверка: ответ релевантен задаче?
        if step_desc and len(step_desc) > 20:
            # Простая эвристика: есть ли общие слова из запроса в ответе
            step_words = set(re.findall(r'[а-яa-z]{4,}', step_desc.lower()))
            result_words = set(re.findall(r'[а-яa-z]{4,}', r))
            overlap = len(step_words & result_words)
            if overlap < 2 and len(step_words) > 3:
                issues.append(f"low_relevance: overlap={overlap}")
        
        return len(issues) == 0, issues
    
    async def execute_with_retry(self, worker, step: Dict, context: Dict, user_id: int) -> Dict:
        """Выполняет шаг с авто-ретраем при проблемах"""
        last_result = None
        
        for attempt in range(self.MAX_RETRIES + 1):
            result = await worker.execute(step, context, user_id)
            
            if not result["success"]:
                if attempt == self.MAX_RETRIES:
                    return result  # возврат ошибки после всех попыток
                # Простой бэк-офф
                import asyncio
                await asyncio.sleep(1 * (attempt + 1))
                continue
            
            # Валидация контента
            ok, issues = self.validate(result.get("result", ""), step.get("desc", ""))
            if ok:
                return result
            
            # Если проблемы и есть попытки — модифицируем контекст для ретрая
            if attempt < self.MAX_RETRIES:
                context["_retry_info"] = {"attempt": attempt + 1, "issues": issues}
                # Можно добавить подсказку в контекст
                context["_hint"] = f"Предыдущая попытка имела проблемы: {', '.join(issues)}. Попробуй ответить полнее."
        
        return last_result or {"success": False, "error": "max_retries_exceeded"}
PY
echo "✅ critic_loop.py"

echo "[6/8] Примеры скилов (tools)..."
# Скилл: поиск в памяти
cat << 'PY' > agents/tools/memory_recall.py
"""Скилл: извлечение данных из памяти пользователя"""

def __skill__():
    return {
        "name": "memory_recall",
        "desc": "Поиск и возврат сохранённых данных пользователя из RAG",
        "params": {"query": "строка запроса", "user_id": "int"},
        "privacy": "LOCAL"
    }

async def memory_recall(query: str, context: dict, user_id: int, **kwargs) -> str:
    """Прямой поиск в хранилище, без LLM"""
    # Используем store из контекста если есть
    store = context.get("store")
    embedder = context.get("embedder")
    
    if not store or not embedder:
        return "⚠️ Хранилище недоступно"
    
    try:
        vec = embedder.embed([query])[0]
        results = store.search(vec, limit=5)
        found = []
        for r in results:
            p = r.get("payload") or r.get("meta") or {}
            if p.get("user_id") in (None, user_id):
                txt = p.get("text") or ""
                if txt and query.lower() in txt.lower():
                    found.append(txt.strip())
        
        if found:
            return "Найдено:\n" + "\n".join(f"• {t}" for t in found[:3])
        return "⚠️ Ничего не найдено по этому запросу в твоей памяти"
    except Exception as e:
        return f"⚠️ Ошибка поиска: {str(e)[:100]}"
PY

# Скилл: сохранение в память
cat << 'PY' > agents/tools/memory_save.py
"""Скилл: сохранение данных в память пользователя"""
import uuid

def __skill__():
    return {
        "name": "memory_save",
        "desc": "Сохранение текста/фактов в приватное хранилище пользователя",
        "params": {"content": "текст для сохранения", "user_id": "int"},
        "privacy": "LOCAL"
    }

async def memory_save(query: str, context: dict, user_id: int, **kwargs) -> str:
    """Сохраняет контент в RAG"""
    store = context.get("store")
    embedder = context.get("embedder")
    
    if not store or not embedder:
        return "⚠️ Хранилище недоступно"
    
    # Извлекаем контент из запроса (после "сохрани:")
    content = query
    if ":" in query:
        content = query.split(":", 1)[1].strip()
    
    try:
        vec = embedder.embed([content])[0]
        payload = {"text": content, "user_id": user_id, "type": "user_memory", "privacy": "HIGH"}
        store.upsert([vec], [payload], [f"mem_{uuid.uuid4().hex[:12]}"])
        return f"✅ Сохранено в твою память: {content[:80]}{'...' if len(content)>80 else ''}"
    except Exception as e:
        return f"⚠️ Ошибка сохранения: {str(e)[:100]}"
PY
echo "✅ tools/memory_recall.py, memory_save.py"

echo "[7/8] Интеграция в orchestrator: агентский режим..."
cat << 'PY' > agents/main/orchestrator.py
import os, sys, uuid, re, asyncio
from pathlib import Path
BASE_DIR = Path(__file__).parent.parent.parent
env_file = BASE_DIR / ".env"
if env_file.exists():
    for ln in env_file.read_text().splitlines():
        if "=" in ln and not ln.strip().startswith("#"):
            k,v = ln.split("=",1); os.environ[k.strip()] = v.strip()
if str(BASE_DIR) not in sys.path: sys.path.insert(0, str(BASE_DIR))

from rag.router.privacy_router import PrivacyRouter
from rag.embed.local_embedder import LocalEmbedder
from rag.store.qdrant_client import RAGStore
from privacy.local_llm.ollama_client import OllamaClient
from privacy.local_llm.openrouter_client import OpenRouterClient
from privacy.vault.token_vault import TokenVault
from agents.brain.registry import registry as skill_registry
from agents.brain.planner import Planner
from agents.brain.worker import Worker
from agents.brain.critic_loop import CriticLoop

class MagicBrain:
    def __init__(self):
        self.router = PrivacyRouter()
        self.embedder = LocalEmbedder()
        self.store = RAGStore()
        self.local_llm = OllamaClient()
        self.cloud_llm = OpenRouterClient(api_key=os.getenv("OPENROUTER_API_KEY"), router=self.router)
        self.vault = TokenVault()
        self.registry = skill_registry
        self.planner = Planner()
        self.critic = CriticLoop()
    
    def _auto_save(self, text: str, user_id: int, role: str):
        try:
            vec = self.embedder.embed([text])[0]
            payload = {"text": text, "user_id": user_id, "role": role, "privacy": "HIGH"}
            self.store.upsert([vec], [payload], [str(uuid.uuid4())])
        except Exception as e:
            print(f"⚠️ RAG save: {e}")
    
    def _direct_rag_return(self, query: str, user_id: int) -> str:
        vec = self.embedder.embed([query])[0]
        results = self.store.search(vec, limit=5)
        found = []
        for r in results:
            p = r.get("payload") or r.get("meta") or {}
            if p.get("user_id") in (None, user_id):
                txt = p.get("text") or ""
                txt = re.sub(r'^(USER|ASSISTANT):\s*', '', txt)
                if txt: found.append(txt)
        if found:
            return "Найдено:\n" + "\n".join(f"• {t}" for t in found[:3])
        return "⚠️ Ничего не найдено"
    
    async def _run_agent_mode(self, query: str, user_id: int, context: dict) -> str:
        """Агентский режим: план → выполнение → критика"""
        available = self.registry.list_available(query)
        plan = self.planner.decompose(query, available)
        
        if len(plan) == 1 and not plan[0]["skill"]:
            # Простой запрос — не нужна агентская логика
            return None
        
        worker = Worker(self)
        results = []
        exec_context = {**context, "store": self.store, "embedder": self.embedder}
        
        for i, step in enumerate(plan):
            # Ждём зависимости если есть
            if step.get("depends_on") is not None and step["depends_on"] < len(results):
                exec_context["_prev_result"] = results[step["depends_on"]]
            
            # Выполнение с ретраем
            result = await self.critic.execute_with_retry(worker, step, exec_context, user_id)
            
            if result["success"]:
                results.append(result["result"])
                exec_context[f"_step_{i}_result"] = result["result"]
            else:
                results.append(f"⚠️ Шаг {i+1} не выполнен: {result.get('error','')}")
        
        # Формируем финальный ответ
        if len(results) == 1:
            return results[0]
        return "Выполнено:\n" + "\n\n".join(f"{i+1}. {r}" for i, r in enumerate(results))
    
    async def process(self, user_query: str, user_id: int, task_type: str = "default") -> dict:
        self._auto_save(f"USER: {user_query}", user_id, "query")
        mode = self.router.classify(user_query)
        
        # Прямой возврат для извлечения
        if mode == "LOCAL" and any(kw in user_query.lower() for kw in ["покажи", "напомни", "мой пароль", "что я сохранял"]):
            direct = self._direct_rag_return(user_query, user_id)
            if direct and "⚠️" not in direct:
                self._auto_save(f"ASSISTANT: {direct}", user_id, "response")
                return {"reply": direct, "privacy_mode": "LOCAL", "model_used": "rag_direct", "context_used": 0}
        
        # === АГЕНТСКИЙ РЕЖИМ ===
        agent_context = {"rag_results": [], "user_id": user_id}
        agent_response = await self._run_agent_mode(user_query, user_id, agent_context)
        
        # Если агентский режим дал результат — используем его
        if agent_response and not agent_response.startswith("⚠️"):
            self._auto_save(f"ASSISTANT: {agent_response}", user_id, "response")
            return {"reply": agent_response, "privacy_mode": mode, "model_used": "agent", "context_used": 0}
        
        # === FALLBACK: обычный LLM-поток ===
        prompt = user_query
        tokens = {}
        if mode == "CLOUD" and self.router.needs_scrubbing(user_query):
            prompt, tokens = self.vault.scrub(user_query)
        
        vec = self.embedder.embed([prompt])[0]
        results = self.store.search(vec, limit=5)
        ctx_texts = [(r.get("payload") or r.get("meta") or {}).get("text", "") for r in results]
        agent_context["rag_results"] = ctx_texts
        
        system = "Отвечай подробно. Если видишь [__SCRUB_*__] — включи как есть."
        full_prompt = f"{system}\n\nКонтекст:\n" + "\n---\n".join(ctx_texts) + f"\n\nЗапрос: {prompt}"
        
        try:
            if mode == "LOCAL":
                response = await self.local_llm.chat(model="qwen2.5:3b", prompt=full_prompt, context=[])
                model_used = "qwen2.5:3b"
            else:
                response = await self.cloud_llm.chat(prompt=full_prompt, context=[])
                model_used = "cloud"
        except Exception as e:
            response = await self.local_llm.chat(model="qwen2.5:3b", prompt=full_prompt, context=[])
            model_used = "qwen2.5:3b (fallback)"
        
        if tokens and mode == "CLOUD":
            response = self.vault.unscrub(response, tokens)
            missing = [v for v in tokens.values() if v not in response]
            if missing:
                response = re.sub(r'\n*[-#*]*\s*(Важное замечание|Примечание).*?(?=\n\n|\Z)', '', response, flags=re.DOTALL|re.IGNORECASE)
                response += f"\n\n[Данные: {', '.join(missing)}]"
        
        self._auto_save(f"ASSISTANT: {response}", user_id, "response")
        return {"reply": response, "privacy_mode": mode, "model_used": model_used, "context_used": len(ctx_texts)}
PY
echo "✅ orchestrator: интеграция агентов"

echo "[8/8] Перезапуск..."
pkill -f uvicorn 2>/dev/null || true
sleep 3
set -a; source $BASE/.env; set +a
cd $BASE/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health && echo "✅ API UP" || echo "❌ API DOWN"

echo ""
echo "🤖 Агенты готовы! Тесты:"
echo "  1. 'Напомни мой пароль от почты' → прямой возврат из RAG"
echo "  2. 'Сначала найди рецепт борща, потом сохрани его' → план из 2 шагов"
echo "  3. 'Посчитай: 150 * 3 + 25' → скилл calculator (если добавишь)"
echo "  4. 'Мой пароль = Test123' → сохранение + токенизация для облака"
echo ""
echo "📁 Добавляй скиллы в agents/tools/*.py с декоратором __skill__()"
echo "🔄 /admin/api/skills/reload — обновить реестр без перезапуска"
echo ""
echo "ЖДУ: тесты или ОК."
