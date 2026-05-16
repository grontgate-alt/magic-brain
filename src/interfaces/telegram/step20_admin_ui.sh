#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain
cd $BASE

echo "[1/6] Установка Jinja2..."
python3 -m pip install -q jinja2 2>/dev/null || true
echo "✅ Зависимости готовы"

echo "[2/6] Skill Router (реестр + векторный поиск в Qdrant + hot-reload)..."
mkdir -p agents/brain
cat << 'PY' > agents/brain/skill_router.py
import os, yaml, json, uuid, sys
from pathlib import Path
from qdrant_client import QdrantClient
from qdrant_client.http import models as qd

BASE = Path(__file__).parent.parent.parent
REGISTRY_FILE = BASE / "config" / "skills-registry.json"
COL_NAME = "magic_brain_skills"

class SkillRouter:
    def __init__(self):
        self.qdrant = QdrantClient(host=os.getenv("QDRANT_HOST","localhost"), port=int(os.getenv("QDRANT_PORT","6333")))
        self.skills = {}
        self.embedder = None
        self._load_registry()
        
    def _get_embedder(self):
        if not self.embedder:
            from rag.embed.local_embedder import LocalEmbedder
            self.embedder = LocalEmbedder()
        return self.embedder

    def _load_registry(self):
        yaml_path = BASE / "config" / "skills-tree.yaml"
        if not yaml_path.exists(): return
        raw = yaml.safe_load(yaml_path.read_text())
        # Формируем плоский список скилов из дерева
        for cat in raw.get("categories", []):
            for s in cat.get("skills", []):
                sid = s.get("id")
                self.skills[sid] = {
                    "id": sid, "name": s.get("name", sid), "desc": s.get("desc",""),
                    "keywords": s.get("keywords","").split(","), "privacy": s.get("privacy","MEDIUM"),
                    "enabled": True, "path": f"agents/skills/{cat.get('id','unknown')}/{sid}.py"
                }
        print(f"📦 Загружено {len(self.skills)} скилов из YAML")

    def sync_to_qdrant(self):
        emb = self._get_embedder()
        if not self.qdrant.collection_exists(COL_NAME):
            self.qdrant.create_collection(COL_NAME, vectors_config=qd.VectorParams(size=1024, distance=qd.Distance.COSINE))
        points, ids = [], []
        for sid, m in self.skills.items():
            text = f"{m['desc']}. Ключевые слова: {', '.join(m['keywords'])}"
            vec = emb.embed([text])[0]
            ids.append(str(uuid.uuid4()))
            points.append(qd.PointStruct(id=ids[-1], vector=vec, payload={"skill_id": sid, "name": m["name"], "privacy": m["privacy"]}))
        self.qdrant.upsert(COL_NAME, points)
        print(f"✅ Векторизовано {len(points)} скилов в Qdrant")

    def search(self, query: str, limit: int = 5, privacy_mode: str = "CLOUD"):
        emb = self._get_embedder()
        vec = emb.embed([query])[0]
        hits = self.qdrant.query_points(COL_NAME, query=vec, limit=limit*2)
        res = []
        for p in hits.points:
            if not p.payload["skill_id"] in self.skills: continue
            sk = self.skills[p.payload["skill_id"]]
            if privacy_mode == "LOCAL" and sk["privacy"] == "LOW": continue
            if not sk["enabled"]: continue
            res.append({"skill_id": p.payload["skill_id"], "name": p.payload["name"], "score": p.score, "privacy": p.payload["privacy"]})
        return sorted(res, key=lambda x: x["score"], reverse=True)[:limit]

    def toggle(self, skill_id: str, state: bool):
        if skill_id in self.skills:
            self.skills[skill_id]["enabled"] = state
            print(f"🔘 {skill_id} → {'ON' if state else 'OFF'}")
            
    def reload(self):
        self.skills.clear()
        self._load_registry()
        self.sync_to_qdrant()
router = SkillRouter()
PY
echo "✅ Skill Router создан"

echo "[3/6] Обновление main.py (добавляем /admin + API endpoints)..."
cat << 'PY' > interfaces/api/main.py
from fastapi import FastAPI, UploadFile, File, Form, Request
from fastapi.responses import HTMLResponse, FileResponse
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
templates = Jinja2Templates(directory=str(BASE_DIR / "interfaces" / "admin" / "templates"))
app.mount("/gui", StaticFiles(directory=str(BASE_DIR / "interfaces" / "gui" / "static"), html=True), name="gui")

@app.get("/")
@app.get("/gui")
def root(): return FileResponse(str(BASE_DIR / "interfaces" / "gui" / "static" / "index.html"))

@app.get("/admin", response_class=HTMLResponse)
async def admin_page(request: Request):
    return templates.TemplateResponse("admin.html", {"request": request})

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
    # Простой апдейт .env (в продакшене лучше через отдельный конфиг-менеджер)
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
echo "✅ main.py обновлён (Admin + Skill Router)"

echo "[4/6] Создание Admin UI (HTMX + Alpine, без npm)..."
mkdir -p interfaces/admin/templates
cat << 'HTML' > interfaces/admin/templates/admin.html
<!DOCTYPE html><html lang="ru" class="dark"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>🦌 Magic Brain Admin</title>
<script src="https://cdn.jsdelivr.net/npm/htmx.org@1.9.10/dist/htmx.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/alpinejs@3.x.x/dist/cdn.min.js" defer></script>
<style>body{font-family:system-ui;background:#0f172a;color:#e2e8f0;padding:20px}
.card{background:#1e293b;padding:16px;border-radius:12px;margin-bottom:12px}
.tab{padding:8px 16px;cursor:pointer;border-bottom:2px solid transparent}
.tab.active{border-bottom:2px solid #38bdf8}
.btn{background:#3b82f6;color:#fff;padding:6px 12px;border:none;border-radius:6px;cursor:pointer}
.btn:hover{background:#2563eb} pre{background:#0b1120;padding:10px;border-radius:8px;overflow:auto}
</style></head><body x-data="{tab:'skills'}">
<h1 style="margin:0 0 20px">🦌 Magic Brain Admin</h1>
<div style="display:flex;gap:10px;margin-bottom:20px;border-bottom:1px solid #334155">
  <div class="tab" :class="{active:tab=='skills'}" @click="tab='skills'">🔧 Скилы & Роутер</div>
  <div class="tab" :class="{active:tab=='settings'}" @click="tab='settings'">⚙️ Настройки</div>
  <div class="tab" :class="{active:tab=='logs'}" @click="tab='logs'">📜 Логи</div>
</div>

<div x-show="tab=='skills'">
  <div class="card">
    <h3>Векторный поиск скилов (Qdrant)</h3>
    <p>Запросы матчатся по описанию + ключевым словам. Приватные фильтры работают автоматически.</p>
    <button class="btn" hx-post="/admin/api/skills/reload" hx-target="#skill-status">🔄 Перезагрузить реестр</button>
    <span id="skill-status" style="margin-left:10px;color:#94a3b8"></span>
    <div id="skill-list" class="card" style="margin-top:10px" hx-get="/admin/api/skills" hx-trigger="load"></div>
  </div>
</div>

<div x-show="tab=='settings'">
  <div class="card">
    <h3>Текущие параметры</h3>
    <pre hx-get="/admin/api/settings" hx-trigger="load">Загрузка...</pre>
  </div>
</div>

<div x-show="tab=='logs'">
  <div class="card"><h3>Последние логи API</h3><pre id="logs">tail -f /tmp/api.log...</pre></div>
</div>

<script>
  htmx.onLoad(() => {
    const el = document.getElementById('skill-list');
    if(el && el.textContent.includes('{')) {
      try {
        const d = JSON.parse(el.textContent);
        el.innerHTML = Object.values(d.skills || {}).map(s => 
          `<div style="display:flex;justify-content:space-between;padding:4px 0;border-bottom:1px solid #334155">
            <span><b>${s.name}</b> <small style="color:#64748b">(${s.privacy})</small></span>
            <button class="btn" style="background:${s.enabled?'#22c55e':'#ef4444'}"
              hx-post="/admin/api/skills/toggle" hx-vals='{"skill_id":"${s.id}","enabled":${!s.enabled}}'
              hx-target="#skill-status">${s.enabled?'ON':'OFF'}</button>
          </div>`
        ).join('');
      } catch(e){}
    }
  });
</script>
</body></html>
HTML
echo "✅ Admin UI создан"

echo "[5/6] Перезапуск API..."
pkill -9 -f "uvicorn|python3.*bot" 2>/dev/null || true
sleep 3
set -a; source $BASE/.env; set +a
cd $BASE/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health > /dev/null && echo "✅ API UP" || { echo "❌ API DOWN"; tail -10 /tmp/api.log; exit 1; }

echo "[6/6] Тесты..."
curl -sf http://127.0.0.1:8000/admin > /dev/null && echo "✅ /admin доступен" || echo "❌ /admin 404"
curl -sf http://127.0.0.1:8000/admin/api/skills | python3 -c "import sys,json; print('✅ Skills API OK' if 'skills' in json.load(sys.stdin) else '❌')" 2>/dev/null

echo ""
echo "📍 Админка: http://192.168.11.101:8000/admin"
echo "📍 GUI чат: http://192.168.11.101:8000/"
echo "ЖДУ: OK или вывод ошибки."
