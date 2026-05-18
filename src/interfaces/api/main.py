# -*- coding: utf-8 -*-
import sys, json, logging, os, time
from pathlib import Path
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, RedirectResponse
from pydantic import BaseModel

# Фикс кракозябр и UTF-8 в логах/ответах
sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

sys.path.insert(0, str(Path(__file__).parent.parent.parent))
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s", force=True)
app = FastAPI(title="Magic Brain API", version="2.3")

@app.on_event("startup")
async def startup():
    from agents.brain.registry import registry
    await registry.reload()
    print(f"✅ Registry preloaded: {len(registry.skills)} tools")

app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_credentials=True, allow_methods=["*"], allow_headers=["*"])

class ProcessRequest(BaseModel):
    user_id: int
    text: str
    force_mode: str | None = None
    force_agent: bool | None = False

@app.get("/")
async def root(): return {"message": "Magic Brain API", "health": "/health"}

@app.get("/health")
async def health(): return {"status": "ok"}

@app.post("/process")
async def process(req: ProcessRequest):
    logging.info(f"📥 Request: user={req.user_id}, force={req.force_mode}")
    try:
        from agents.main.orchestrator import MagicBrain
        result = await MagicBrain().process(req.text, req.user_id, force_mode=req.force_mode, force_agent=req.force_agent)
        return result
    except Exception as e:
        logging.exception("💥 /process failed")
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
