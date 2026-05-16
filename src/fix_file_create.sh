#!/bin/bash
set -e
cd ~/magic-brain

echo "[1/2] Orchestrator: умный парсер создания файлов..."
cat << 'PY' > agents/main/orchestrator.py
import os, sys, uuid, re, asyncio, json, logging, time
from pathlib import Path
BASE_DIR = Path(__file__).parent.parent.parent
env_file = BASE_DIR / ".env"
if env_file.exists():
    for ln in env_file.read_text().splitlines():
        if "=" in ln and not ln.strip().startswith("#"): k,v=ln.split("=",1); os.environ[k.strip()]=v.strip()
if str(BASE_DIR) not in sys.path: sys.path.insert(0, str(BASE_DIR))

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s', force=True)
from rag.router.privacy_router import PrivacyRouter
from rag.embed.local_embedder import LocalEmbedder
from rag.store.qdrant_client import RAGStore
from privacy.local_llm.ollama_client import OllamaClient
from privacy.local_llm.openrouter_client import OpenRouterClient
from privacy.vault.token_vault import TokenVault
from agents.brain.planner import Planner
from agents.brain.worker import Worker
from agents.brain.critic_loop import CriticLoop
from agents.brain.intent_router import intent_router
from agents.brain.session import session_manager
from agents.brain.registry import registry
from agents.mcp.client import mcp as mcp_direct

class MagicBrain:
    def __init__(self):
        logging.info("🧠 Init MagicBrain...")
        self.router = PrivacyRouter(); self.embedder = LocalEmbedder(); self.store = RAGStore()
        self.local_llm = OllamaClient()
        self.cloud_llm = OpenRouterClient(api_key=os.getenv("OPENROUTER_API_KEY"), router=self.router)
        self.vault = TokenVault(); self.planner = Planner(); self.critic = CriticLoop(); self.worker = Worker(self)

    def _auto_save(self, t, u, r):
        try:
            v = self.embedder.embed([t])[0]
            self.store.upsert([v], [{"text":t,"user_id":u,"role":r,"privacy":"HIGH"}], [str(uuid.uuid4())])
        except: pass

    def _tag(self, m, mdl, c): return f"[{'🛠️' if m=='tools' else '💬'}{mdl}{' +RAG:'+str(c) if c else ''}]"

    def _parse_file_create(self, query: str) -> tuple[str, str] | None:
        """
        Парсит запросы типа:
        • "создай файл 111.txt и запиши туда стихи"
        • "сохрани в ~/test.txt текст: привет"
        Возвращает (path, content) или None
        """
        q = query.lower()
        if not any(k in q for k in ["создай файл","запиши в файл","сохрани в файл","напиши в файл"]):
            return None
        
        # === Извлекаем путь к файлу ===
        # Вариант 1: явный путь /... или ~/...
        path_match = re.search(r'(/[a-zA-Z0-9./_~-]+|~/[a-zA-Z0-9./_~-]+)', query)
        if path_match:
            path = path_match.group(0)
        else:
            # Вариант 2: просто имя файла (111.txt, test.py)
            fname_match = re.search(r'(?:файл|в)\s+([a-zA-Z0-9а-яА-ЯёЁ_-]+\.[a-zA-Z0-9]+)', query)
            if fname_match:
                path = f"~/{fname_match.group(1)}"  # нормализуем в домашнюю директорию
            else:
                return None  # не нашли путь
        
        # === Извлекаем контент ===
        # Ключевые слова после которых идёт контент
        content_markers = ["напиши туда","запиши туда","содержимое:","текст:","следующее:","вот:","\"","\"\""]
        content = None
        for marker in content_markers:
            if marker in q:
                # Берём всё после маркера
                idx = q.find(marker)
                content = query[idx + len(marker):].strip()
                break
        
        # Если контент не найден — берём всё после упоминания файла
        if not content:
            after_file = re.split(r'(?:файл|в)\s+[^\s]+', query, maxsplit=1)
            if len(after_file) > 1:
                content = after_file[1].strip()
        
        # Если всё ещё пусто — заглушка
        if not content:
            content = "[Пустой файл]"
        
        # Очистка: убираем лишние кавычки, пробелы
        content = content.strip().strip('"').strip("'")
        
        return path, content

    async def _mcp(self, query: str, user_id: int) -> str:
        q = query.lower()
        
        # === Обработка создания/записи файлов ===
        file_parse = self._parse_file_create(query)
        if file_parse:
            path, content = file_parse
            logging.info(f"📝 File create: path={path}, content_len={len(content)}")
            try:
                result = await asyncio.wait_for(
                    mcp_direct.execute("mcp_filesystem_write_file", {"path": path, "content": content}),
                    timeout=30
                )
                return f"✅ Файл создан: {path}\n{result}" if result else f"✅ Файл создан: {path}"
            except asyncio.TimeoutError:
                return "⏱️ Таймаут записи файла"
            except Exception as e:
                err = str(e)
                if "permission denied" in err.lower() or "eperm" in err.lower():
                    return f"⚠️ Нет прав на запись в {path}\nMCP ограничен директорией ~/ (твоя домашняя папка). Попробуй путь вида ~/111.txt"
                return f"⚠️ Ошибка записи: {err[:150]}"
        
        # === Чтение/список файлов (пути с / или ~/) ===
        path_match = re.search(r'(/[a-zA-Z0-9./_~-]+|~/[a-zA-Z0-9./_~-]+)', q)
        if path_match:
            path = path_match.group(0)
            if any(k in q for k in ["прочитай","открой","покажи содержимое","читать","текст","содержимое"]):
                tool, args = "mcp_filesystem_read_text_file", {"path": path}
            elif any(k in q for k in ["список","каталог","ls","dir","файлы в","покажи","папки"]):
                tool, args = "mcp_filesystem_list_directory", {"path": path}
            else:
                tool, args = "mcp_filesystem_list_directory", {"path": path}
            
            try:
                r = await asyncio.wait_for(mcp_direct.execute(tool, args), timeout=25)
                return str(r) if r else "✅ Выполнено"
            except asyncio.TimeoutError: return "⏱️ Таймаут файла"
            except Exception as e:
                err = str(e)
                if "permission denied" in err.lower():
                    return f"⚠️ Нет доступа к {path}\nMCP работает только внутри твоей домашней директории."
                return f"⚠️ Файл: {err[:150]}"

        # === GitHub поиск ===
        if any(k in q for k in ["github","репозиторий","репо"]):
            s = re.search(r'(?:про|о|найти|поиск).*?([a-zA-Z0-9а-яА-ЯёЁ_\-\s]{3,})', q, re.I)
            q_arg = s.group(1).strip() if s else "ai"
            try: return await asyncio.wait_for(mcp_direct.execute("mcp_github_search_repositories", {"query": q_arg}), timeout=25)
            except: return "⚠️ GitHub error"
        return None

    async def process(self, user_query: str, user_id: int, task_type: str = "default", 
                      force_agent: bool = False, force_mode: str = None, intent_override: str = None) -> dict:
        start = time.time()
        self._auto_save(f"USER: {user_query}", user_id, "query")
        
        if force_agent or force_mode=="tools" or "/home" in user_query or "~/" in user_query or "создай файл" in user_query.lower():
            r = await self._mcp(user_query, user_id)
            if r and not r.startswith("⚠️"): return {"reply":r,"privacy_mode":"tools","model_used":"mcp","context_used":0,"tag":self._tag("tools","mcp",0)}
        
        if time.time()-start > 30: return {"reply":"⏱️ Таймаут","privacy_mode":"LOCAL","model_used":"timeout","context_used":0,"tag":"[⏱️]"}
        
        try:
            pm = self.router.classify(user_query)
            prompt, tokens = user_query, {}
            if pm=="CLOUD" and self.router.needs_scrubbing(user_query): prompt, tokens = self.vault.scrub(user_query)
            vec = self.embedder.embed([prompt])[0]
            ctx = [(r.get("payload") or r.get("meta") or {}).get("text","") for r in self.store.search(vec, limit=2)]
            sys_prompt = "Отвечай кратко."
            fp = f"{sys_prompt}\n\nЗапрос: {prompt}"
            
            if pm=="LOCAL":
                resp = await asyncio.wait_for(self.local_llm.chat(model="qwen2.5:3b", prompt=fp, context=[]), timeout=15)
                mu = "qwen2.5:3b"
            else:
                resp = await asyncio.wait_for(self.cloud_llm.chat(prompt=fp, context=[]), timeout=15)
                mu = "cloud"
            if tokens and pm=="CLOUD": resp = self.vault.unscrub(resp, tokens)
            self._auto_save(f"ASSISTANT: {resp}", user_id, "response")
            return {"reply":resp,"privacy_mode":pm,"model_used":mu,"context_used":len(ctx),"tag":self._tag("chat",mu,len(ctx))}
        except asyncio.TimeoutError: return {"reply":"⏱️ Таймаут LLM","privacy_mode":"LOCAL","model_used":"timeout","context_used":0,"tag":"[⏱️]"}
        except Exception as e: return {"reply":f"⚠️ {str(e)[:80]}","privacy_mode":"LOCAL","model_used":"error","context_used":0,"tag":"[❌]"}
PY
echo "✅ orchestrator: фикс парсера файлов"

echo "[2/2] Перезапуск..."
pkill -9 -f uvicorn 2>/dev/null || true; pkill -9 -f "bot.py" 2>/dev/null || true; sleep 2
set -a; source ~/magic-brain/.env; set +a
cd ~/magic-brain/interfaces/api; nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
cd ~/magic-brain/interfaces/telegram; nohup python3 bot.py > /tmp/bot.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health && echo "✅ API UP" || echo "❌ API DOWN"

echo ""
echo "🎉 Исправлено:"
echo "  • Путь '111.txt' → автоматически ~/111.txt"
echo "  • Контент извлекается после 'напиши туда', 'запиши', ':'"
echo "  • Чёткая ошибка при permission denied"
echo ""
echo "🧪 Тест:"
echo "  • 'Создай файл 111.txt и запиши туда: привет мир'"
echo "  • 'Покажи ~/111.txt'"
echo ""
echo "ЖДУ: результат."
