#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain
cd $BASE

echo "=== 1. Сырой ответ от /v1/chat/completions ==="
RAW=$(curl -s -w "\n===HTTP:%{http_code}===" -X POST http://127.0.0.1:8000/v1/chat/completions \
  -H "Content-Type: application/json" --max-time 60 \
  -d '{"model":"magic-brain","messages":[{"role":"user","content":"привет"}]}')
echo "$RAW"

echo ""
echo "=== 2. Лог API (последние 30 строк) ==="
tail -30 /tmp/api.log

echo ""
echo "=== 3. Фикс: более надёжный /v1/chat/completions с логом ошибок ==="
cat << 'PY' > interfaces/api/main.py
from fastapi import FastAPI, UploadFile, File, Form
from fastapi.responses import HTMLResponse, FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field
from typing import List, Optional, Literal
import os, sys, uuid, json, time, traceback
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
app.mount("/gui", StaticFiles(directory=str(BASE_DIR / "interfaces" / "gui" / "static"), html=True), name="gui")

@app.get("/")
@app.get("/gui")
def root(): return FileResponse(str(BASE_DIR / "interfaces" / "gui" / "static" / "index.html"))

@app.get("/admin", response_class=HTMLResponse)
async def admin_page():
    return HTMLResponse("""<!DOCTYPE html><html lang="ru" class="dark"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>🦌 Magic Brain Admin</title>
<script src="https://cdn.jsdelivr.net/npm/htmx.org@1.9.10/dist/htmx.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/alpinejs@3.x.x/dist/cdn.min.js" defer></script>
<style>body{font-family:system-ui;background:#0f172a;color:#e2e8f0;padding:20px;margin:0}
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
  <div class="card"><h3>Векторный поиск скилов (Qdrant)</h3>
    <button class="btn" hx-post="/admin/api/skills/reload" hx-target="#skill-status">🔄 Перезагрузить</button>
    <span id="skill-status" style="margin-left:10px;color:#94a3b8"></span>
    <div id="skill-list" class="card" style="margin-top:10px" hx-get="/admin/api/skills" hx-trigger="load"></div>
  </div>
</div>
<div x-show="tab=='settings'">
  <div class="card"><h3>Параметры</h3><pre hx-get="/admin/api/settings" hx-trigger="load">Загрузка...</pre></div>
</div>
<div x-show="tab=='logs'">
  <div class="card"><h3>Логи</h3><pre id="logs">tail -f /tmp/api.log...</pre></div>
</div>
<script>htmx.onLoad(()=>{const el=document.getElementById('skill-list');if(el&&el.textContent.includes('{')){try{const d=JSON.parse(el.textContent);el.innerHTML=Object.values(d.skills||{}).map(s=>`<div style="display:flex;justify-content:space-between;padding:4px 0;border-bottom:1px solid #334155"><span><b>${s.name}</b><small style="color:#64748b">(${s.privacy})</small></span><button class="btn" style="background:${s.enabled?'#22c55e':'#ef4444'}" hx-post="/admin/api/skills/toggle" hx-vals='{"skill_id":"${s.id}","enabled":${!s.enabled}}' hx-target="#skill-status">${s.enabled?'ON':'OFF'}</button></div>`).join('')}catch(e){}}});</script>
</body></html>""")

# === OpenAI-Compatible API ===
class ChatMessage(BaseModel):
    role: Literal["user","assistant","system","tool"]
    content: str
class ChatCompletionRequest(BaseModel):
    model: str = "magic-brain"
    messages: List[ChatMessage]
    temperature: float = 0.7
    max_tokens: Optional[int] = None
    stream: bool = False
class ChatChoice(BaseModel):
    index: int = 0
    message: ChatMessage
    finish_reason: str = "stop"
class ChatCompletionResponse(BaseModel):
    id: str = Field(default_factory=lambda: f"chatcmpl-{uuid.uuid4().hex[:8]}")
    object: str = "chat.completion"
    created: int = Field(default_factory=lambda: int(time.time()))
    model: str
    choices: List[ChatChoice]
    usage: dict = {"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}

@app.post("/v1/chat/completions")
async def openai_chat(req: ChatCompletionRequest):
    try:
        user_msg = next((m.content for m in reversed(req.messages) if m.role=="user"), "")
        if not user_msg:
            return JSONResponse(status_code=400, content={"error":"No user message"})
        
        if not hasattr(openai_chat, "brain"):
            from agents.main.orchestrator import MagicBrain
            openai_chat.brain = MagicBrain()
            print("✅ Orchestrator loaded for OpenAI endpoint")
        
        # Позиционные аргументы + лог
        print(f"🔍 OpenAI call: user_id=999, query='{user_msg[:50]}...'")
        result = await openai_chat.brain.process(user_msg, 999, "chat")
        
        reply = result.get("reply", "⚠️ Нет ответа")
        mode = result.get("privacy_mode", "UNKNOWN")
        if mode == "LOCAL": reply = f"🔐 {reply}"
        
        resp = ChatCompletionResponse(
            model=req.model,
            choices=[ChatChoice(message=ChatMessage(role="assistant", content=reply))]
        )
        print(f"✅ OpenAI response sent ({len(reply)} chars)")
        return resp
        
    except Exception as e:
        err = f"{type(e).__name__}: {str(e)}"
        trace = traceback.format_exc()
        print(f"❌ OpenAI endpoint error: {err}")
        print(trace)
        return JSONResponse(status_code=500, content={"error": err, "trace": trace[:500]})

@app.get("/v1/models")
async def list_models():
    return {"object":"list","data":[{"id":"magic-brain","object":"model","owned_by":"local"}]}

# === Остальные эндпоинты ===
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
echo "✅ main.py обновлён с улучшенным логированием"

echo "[4/4] Перезапуск и тест..."
pkill -9 -f "uvicorn" 2>/dev/null || true
sleep 3
set -a; source $BASE/.env; set +a
cd $BASE/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 8

echo "Тест /v1/chat/completions (60с таймаут)..."
RESP=$(curl -s -w "\n===HTTP:%{http_code}===" -X POST http://127.0.0.1:8000/v1/chat/completions \
  -H "Content-Type: application/json" --max-time 60 \
  -d '{"model":"magic-brain","messages":[{"role":"user","content":"привет"}]}')
echo "=== RAW RESPONSE ==="
echo "$RESP"
echo "=== END ==="

echo ""
echo "=== Последние 20 строк лога ==="
tail -20 /tmp/api.log

echo ""
echo "Если в ответе есть 'choices' и 'message' — всё ОК. Если 500 — скинь лог."
echo "ЖДУ: вывод."
