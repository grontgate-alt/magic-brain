#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain

echo "[1/5] Установка multipart (для загрузки файлов)..."
python3 -m pip install --break-system-packages -q python-multipart 2>/dev/null || true
echo "✅ Зависимость готова"

echo "[2/5] Обновление main.py (фикс 404 GUI + Ingest)..."
cat << 'PY' > $BASE/interfaces/api/main.py
from fastapi import FastAPI, UploadFile, File, Form
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
import os, sys, uuid
from pathlib import Path

BASE_DIR = Path(__file__).parent.parent.parent
if str(BASE_DIR) not in sys.path: sys.path.insert(0, str(BASE_DIR))

_embedder = None
_store = None

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

# Фикс 404: отдаём HTML и на корне, и на /gui
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
    return {"mode": router.classify("пароль от почты"), "scrubbed": router.scrub("email: test@example.com")}

@app.post("/ingest")
async def ingest(file: UploadFile = File(None), text: str = Form(None), privacy: str = Form("HIGH")):
    raw = ""; src = "api_text"
    if file:
        raw = (await file.read()).decode("utf-8", errors="ignore")
        src = file.filename
    elif text:
        raw = text
    else: return {"error": "Нет данных"}
    
    if len(raw.strip()) < 10: return {"error": "Текст слишком короткий"}
    
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
    try: return await process.brain.process(req.text, req.user_id, req.task_type)
    except Exception as e:
        import traceback
        return {"error": str(e), "status": "failed", "reply": "⚠️ Ошибка"}
PY
echo "✅ main.py обновлен"

echo "[3/5] Перезапуск API..."
pkill -9 -f "uvicorn|python3.*bot" 2>/dev/null || true
sleep 3
set -a; source $BASE/.env; set +a
cd $BASE/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health > /dev/null && echo "✅ API UP" || { echo "❌ API DOWN"; tail -10 /tmp/api.log; exit 1; }

echo "[4/5] Тест GUI..."
echo -n "🔹 GUI (http://localhost:8000/): "
RESP=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8000/)
[ "$RESP" = "200" ] && echo "✅ 200 OK" || echo "❌ HTTP $RESP"

echo "[5/5] Тест Ingest..."
echo -n "🔹 Ingest (текст в базу): "
ING=$(curl -s -X POST http://127.0.0.1:8000/ingest \
  -F "text=Квантовые компьютеры используют кубиты для вычислений. Это важно для RAG." \
  -F "privacy=HIGH" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','❌'))")
[ "$ING" = "ok" ] && echo "✅ Ingest OK" || echo "❌ $ING"

echo ""
echo "📍 GUI: http://192.168.11.101:8000/"
echo "ЖДУ: вывод."
