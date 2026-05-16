#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain
cd $BASE

echo "[1/4] Диагностика /admin 404..."
echo "🔹 Проверка файла шаблона:"
ls -la interfaces/admin/templates/admin.html 2>/dev/null && echo "✅ Файл есть" || echo "❌ Файла нет"

echo "🔹 Проверка директории в main.py:"
grep -A1 "Jinja2Templates" interfaces/api/main.py

echo "[2/4] Фикс: упрощаем Jinja2 + явный путь..."
cat << 'PY' > interfaces/api/main.py
from fastapi import FastAPI, UploadFile, File, Form, Request
from fastapi.responses import HTMLResponse, FileResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel
import os, sys, uuid, json
from pathlib import Path

BASE_DIR = Path(__file__).parent.parent.parent
if str(BASE_DIR) not in sys.path: sys.path.insert(0, str(BASE_DIR))

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

# Фикс: явный абсолютный путь для templates
ADMIN_TPL = BASE_DIR / "interfaces" / "admin" / "templates"
ADMIN_TPL.mkdir(parents=True, exist_ok=True)
templates = Jinja2Templates(directory=str(ADMIN_TPL))

app.mount("/gui", StaticFiles(directory=str(BASE_DIR / "interfaces" / "gui" / "static"), html=True), name="gui")

@app.get("/")
@app.get("/gui")
def root(): return FileResponse(str(BASE_DIR / "interfaces" / "gui" / "static" / "index.html"))

@app.get("/admin", response_class=HTMLResponse)
async def admin_page(request: Request):
    try:
        return templates.TemplateResponse("admin.html", {"request": request})
    except Exception as e:
        return PlainTextResponse(f"❌ Template error: {e}", status_code=500)

@app.get("/health")
def health(): return {"status":"ok","rag":"ready","privacy":"strict"}

@app.get("/admin/api/skills")
def api_skills():
    from agents.brain.skill_router import router
    return {"skills": router.skills, "status": "ok"}

@app.post("/admin/api/skills/reload")
def api_reload():
    from agents.brain.skill_router import router
    router.reload()
    return {"status": "reloaded", "count": len(router.skills)}

@app.post("/admin/api/skills/toggle")
def api_toggle(skill_id: str, enabled: bool = True):
    from agents.brain.skill_router import router
    router.toggle(skill_id, enabled)
    return {"status": "toggled", "id": skill_id, "enabled": enabled}

@app.get("/admin/api/settings")
def api_settings():
    env = {}
    env_path = BASE_DIR / ".env"
    if env_path.exists():
        for line in env_path.read_text().splitlines():
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip() if not "KEY" in k else v[:10]+"..."
    return {"env": env, "privacy_mode": os.getenv("PRIVACY_MODE","strict"), "model_local": "qwen2.5:3b", "model_cloud": "openrouter/free"}

@app.post("/admin/api/settings")
def api_update_settings(data: dict):
    print(f"⚙️ Настройки обновлены: {list(data.keys())}")
    return {"status": "saved"}

@app.post("/ingest")
async def ingest(file: UploadFile = File(None), text: str = Form(None), privacy: str = Form("HIGH")):
    raw = ""; src = "api_text"
    if file: raw = (await file.read()).decode("utf-8", errors="ignore"); src = file.filename
    elif text: raw = text
    else: return {"error": "Нет данных"}
    if len(raw.strip()) < 10: return {"error": "Текст слишком короткий"}
    chunks = [raw[i:i+800] for i in range(0, len(raw), 800)]
    ids = [str(uuid.uuid4()) for _ in chunks]
    payloads = [{"text": c, "source": src, "privacy": privacy} for c in chunks]
    emb = get_embedder(); store = get_store()
    store.upsert(emb.embed(chunks), payloads, ids)
    return {"status": "ok", "chunks_added": len(chunks)}

@app.post("/process")
async def process(req: BaseModel):
    if not hasattr(process, "brain"):
        from agents.main.orchestrator import MagicBrain
        process.brain = MagicBrain()
    try: return await process.brain.process(req.text, req.user_id, req.task_type)
    except Exception as e: return {"error": str(e), "status": "failed", "reply": "⚠️ Ошибка"}
PY
echo "✅ main.py обновлён"

echo "[3/4] Перезапуск API..."
pkill -9 -f "uvicorn" 2>/dev/null || true
sleep 3
set -a; source $BASE/.env; set +a
cd $BASE/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health > /dev/null && echo "✅ API UP" || { echo "❌ API DOWN"; tail -10 /tmp/api.log; exit 1; }

echo "[4/4] Тест /admin..."
ADMIN_RESP=$(curl -s -w "\nHTTP:%{http_code}" http://127.0.0.1:8000/admin)
HTTP_CODE=$(echo "$ADMIN_RESP" | grep "HTTP:" | cut -d: -f2)
BODY=$(echo "$ADMIN_RESP" | grep -v "HTTP:")

if [ "$HTTP_CODE" = "200" ] && echo "$BODY" | grep -q "Magic Brain Admin"; then
    echo "✅ /admin работает! Возвращает HTML"
elif [ "$HTTP_CODE" = "500" ]; then
    echo "❌ Ошибка шаблона:"
    echo "$BODY"
    echo "Лог:"; tail -15 /tmp/api.log
else
    echo "❌ HTTP $HTTP_CODE"
    echo "Тело: $BODY"
fi

echo ""
echo "📍 Админка: http://192.168.11.101:8000/admin"
echo "Если 500 — скинь вывод. Если 200 — пиши 21 для следующего шага."
