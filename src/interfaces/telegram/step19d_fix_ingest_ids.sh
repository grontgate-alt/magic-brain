#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain

echo "[1/4] Фикс /ingest: валидные UUID для Qdrant..."
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
    
    # Чанкинг по 800 символов
    chunks = [raw[i:i+800] for i in range(0, len(raw), 800)]
    
    # ✅ FIX: Валидные UUID для Qdrant (без префиксов)
    ids = [str(uuid.uuid4()) for _ in range(len(chunks))]
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
echo "✅ main.py обновлён (валидные UUID)"

echo "[2/4] Перезапуск API..."
pkill -9 -f "uvicorn" 2>/dev/null || true
sleep 3
set -a; source $BASE/.env; set +a
cd $BASE/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health > /dev/null && echo "✅ API UP" || { echo "❌ API DOWN"; tail -10 /tmp/api.log; exit 1; }

echo "[3/4] Тест Ingest..."
RESP=$(curl -s -X POST http://127.0.0.1:8000/ingest \
  -F "text=Квантовые компьютеры используют кубиты для вычислений. Это важно для криптографии и моделирования молекул." \
  -F "privacy=HIGH")
echo "Ответ: $RESP"
echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print('✅ Ingest OK' if d.get('status')=='ok' else f\"❌ {d}\")" 2>/dev/null || echo "⚠️ Не удалось распарсить ответ"

echo "[4/4] Тест RAG-поиска (чтобы убедиться, что данные записались)..."
echo "Запрос: 'что используют квантовые компьютеры?'"
SEARCH=$(curl -s -X POST http://127.0.0.1:8000/process \
  -H "Content-Type: application/json" --max-time 40 \
  -d '{"user_id":1,"text":"что используют квантовые компьютеры?","task_type":"default"}')
echo "$SEARCH" | python3 -c "
import sys,json
d=json.load(sys.stdin)
r=d.get('reply','')
if 'error' in d: print(f'❌ {d[\"error\"][:100]}')
else: print(f'✅ mode:{d.get(\"privacy_mode\")} | context:{d.get(\"context_used\")} | reply:{r[:100]}...')
"

echo ""
echo "📍 GUI: http://192.168.11.101:8000/"
echo "ЖДУ: вывод. Если '✅ Ingest OK' и есть контекст в ответе — система готова."
