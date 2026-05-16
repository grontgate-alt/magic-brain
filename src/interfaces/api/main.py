import os, sys, logging, time, json
from pathlib import Path
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import Optional, List, Dict

sys.path.insert(0, str(Path(__file__).parent.parent.parent))
logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")

app = FastAPI(title="Magic Brain API", version="2.1")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_credentials=True, allow_methods=["*"], allow_headers=["*"])

class ProcessRequest(BaseModel):
    user_id: int
    text: str
    force_mode: Optional[str] = None
    force_agent: Optional[bool] = False

class ChatMsg(BaseModel):
    role: str
    content: str

class ChatReq(BaseModel):
    model: str
    messages: List[ChatMsg]
    temperature: Optional[float] = 0.7
    stream: Optional[bool] = False

@app.get("/")
async def root():
    return {"message": "Magic Brain API", "health": "/health", "tools": "/tools", "docs": "/docs"}

@app.get("/health")
async def health():
    return {"status": "ok"}

@app.post("/process")
async def process(req: ProcessRequest):
    logging.info(f"Request: user={req.user_id}, text={req.text[:50]!r}, force={req.force_mode}")
    try:
        from agents.main.orchestrator import MagicBrain
        result = await MagicBrain().process(req.text, req.user_id, force_mode=req.force_mode, force_agent=req.force_agent)
        return result
    except Exception as e:
        logging.error(f"Process error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/tools")
async def list_tools():
    cache = "/tmp/mcp_tools_cache.json"
    if os.path.exists(cache):
        with open(cache) as f: return json.load(f)
    return {"total": 0, "mcp_count": 0, "status": "cache_not_found"}

@app.get("/models")
async def list_models():
    try:
        import httpx
        async with httpx.AsyncClient(timeout=5) as c:
            r = await c.get("http://localhost:11434/api/tags")
            return {"llm": [m["name"] for m in r.json().get("models", [])], "cloud": ["openrouter:auto"]}
    except:
        return {"llm": ["qwen2.5:3b"], "cloud": ["openrouter:auto"]}

@app.post("/v1/chat/completions")
async def openai_chat(req: ChatReq):
    logging.info(f"OpenAI endpoint: model={req.model}, messages={len(req.messages)}")
    try:
        user_msg = next((m.content for m in reversed(req.messages) if m.role == "user"), "")
        force = "agent" in (req.model or "").lower()
        from agents.main.orchestrator import MagicBrain
        res = await MagicBrain().process(user_msg, 9999, force_mode="tools" if force else None, force_agent=force)
        return {
            "id": f"mb-{int(time.time())}", "object": "chat.completion", "created": int(time.time()),
            "model": req.model or "magic-brain",
            "choices": [{"index": 0, "message": {"role": "assistant", "content": res.get("reply", "")}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}
        }
    except Exception as e:
        logging.error(f"OpenAI endpoint error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/v1/models")
async def openai_models():
    try:
        import httpx
        async with httpx.AsyncClient(timeout=5) as c:
            r = await c.get("http://localhost:11434/api/tags")
            models = [{"id": x["name"], "object": "model", "owned_by": "ollama"} for x in r.json().get("models", [])]
        models.append({"id": "magic-brain:agent", "object": "model", "owned_by": "magic-brain"})
        return {"object": "list", "data": models}
    except:
        return {"object": "list", "data": [
            {"id": "qwen2.5:3b", "object": "model", "owned_by": "ollama"},
            {"id": "magic-brain:agent", "object": "model", "owned_by": "magic-brain"}
        ]}


from fastapi.responses import FileResponse

@app.get("/ui")
async def dashboard():
    return FileResponse("/home/der/magic-brain/interfaces/api/dashboard.html")

@app.get("/")
async def root_redirect():
    from fastapi.responses import RedirectResponse
    return RedirectResponse(url="/ui")

from fastapi.responses import FileResponse, RedirectResponse

@app.get("/ui")
async def dashboard():
    return FileResponse("/home/der/magic-brain/interfaces/api/dashboard.html")

@app.get("/")
async def root_redirect():
    return RedirectResponse(url="/ui")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
