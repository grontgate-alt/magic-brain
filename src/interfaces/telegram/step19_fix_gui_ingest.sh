#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain

echo "[1/5] Установка зависимости для загрузки файлов..."
pip install -q python-multipart 2>/dev/null

echo "[2/5] Финальный main.py (фикс GUI + реальный Ingest)..."
cat << 'PY' > $BASE/interfaces/api/main.py
from fastapi import FastAPI, UploadFile, File, Form
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
import os, sys, uuid, re
from pathlib import Path

BASE_DIR = Path(__file__).parent.parent.parent
if str(BASE_DIR) not in sys.path: sys.path.insert(0, str(BASE_DIR))

# Глобальные лази-иниты для RAG (чтобы не грузить модели при старте, если не нужно)
_embedder = None; _store = None
def get_embedder():
    global _embedder
    if not _embedder:
        from rag.embed.local_embedder import LocalEmbedder
        _embedder = LocalEmbedder()
    return _embedder

def get_store():
    global _store
    if not _store:
        from rag.store.qdrant_client import RAGStore
        _store = RAGStore()
    return _store

app = FastAPI(title="Magic Brain API")
GUI_DIR = BASE_DIR / "interfaces" / "gui" / "static"
app.mount("/gui", StaticFiles(directory=str(GUI_DIR), html=True), name="gui")

@app.get("/")
@app.get("/gui")
def root(): return FileResponse(str(GUI_DIR / "index.html"))

class ProcessReq(BaseModel):
    user_id: int; text: str; has_files: bool = False; task_type: str = "default"

@app.get("/health")
def health(): return {"status":"ok","rag":"ready","privacy":"strict"}

@app.get("/test/light")
def light_test():
    from rag.router.privacy_router import PrivacyRouter
    from agents.critic.critic import Critic
    router = PrivacyRouter(); critic = Critic()
    q = "пароль от почты"
    ok, _ = critic.validate("ok response")
    return {"query": q, "mode": router.classify(q), "scrubbed": router.scrub("email: test@example.com"), "critic_ok": not ok}

@app.post("/ingest")
async def ingest(file: UploadFile = File(None), text: str = Form(None), privacy: str = Form("HIGH")):
    raw = ""
    src = "api_text"
    if file:
        raw = (await file.read()).decode("utf-8", errors="ignore")
        src = file.filename
    elif text:
        raw = text
    else:
        return {"error": "Нет данных"}
    
    if len(raw.strip()) < 50:
        return {"error": "Текст слишком короткий (<50 символов)"}
        
    # Чанкинг по 800 символов
    chunks = [raw[i:i+800] for i in range(0, len(raw), 800)]
    ids = [f"ing_{uuid.uuid4().hex[:8]}_{i}" for i in range(len(chunks))]
    payloads = [{"text": c, "source": src, "privacy": privacy} for c in chunks]
    
    emb = get_embedder(); store = get_store()
    vectors = emb.embed(chunks)
    store.upsert(vectors, payloads, ids)
    return {"status": "ok", "chunks_added": len(chunks), "source": src}

@app.post("/process")
async def process(req: ProcessReq):
    if not hasattr(process, "brain"):
        from agents.main.orchestrator import MagicBrain
        process.brain = MagicBrain()
    try:
        return await process.brain.process(req.text, req.user_id, req.task_type)
    except Exception as e:
        import traceback
        return {"error": str(e), "status": "failed", "reply": "⚠️ Ошибка обработки"}
PY

echo "[3/5] Проверка синтаксиса..."
python3 -m py_compile $BASE/interfaces/api/main.py && echo "✅ main.py OK" || { echo "❌ Синтаксис"; exit 1; }

echo "[4/5] Перезапуск API..."
pkill -9 -f "uvicorn|python3.*bot" 2>/dev/null || true
sleep 3
set -a; source $BASE/.env; set +a
cd $BASE/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health > /dev/null && echo "✅ API UP" || { echo "❌ API DOWN"; tail -10 /tmp/api.log; exit 1; }

echo "[5/5] Тесты..."
echo -n "🔹 GUI: "
curl -sf http://127.0.0.1:8000/ > /dev/null && echo "✅ Отдает HTML" || echo "❌ 404"

echo -n "🔹 Ingest (текст): "
ING=$(curl -s -X POST http://127.0.0.1:8000/ingest \
  -F "text=Тестовый документ для RAG. Квантовые компьютеры используют кубиты для вычислений. Это важно для криптографии." \
  -F "privacy=HIGH" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','❌'))")
[ "$ING" = "ok" ] && echo "✅ Ingest OK" || echo "❌ $ING"

echo ""
echo "📍 GUI: http://192.168.11.101:8000/gui/"
echo "📥 Ingest curl: curl -X POST http://localhost:8000/ingest -F 'text=ваш текст' -F 'privacy=HIGH'"
echo "ЖДУ: ОК или лог ошибки."
