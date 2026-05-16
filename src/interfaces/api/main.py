import os
import sys
import logging
import time
import json
from pathlib import Path
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import Optional, Any

sys.path.insert(0, str(Path(__file__).parent.parent.parent))
logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(message)s")

app = FastAPI(title="Magic Brain API")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_credentials=True, allow_methods=["*"], allow_headers=["*"])

# === Models ===
class ProcessRequest(BaseModel):
    user_id: int
    text: str
    force_mode: Optional[str] = None
    force_agent: Optional[bool] = False
    context: Optional[Any] = None

class ChatMessage(BaseModel):
    role: str
    content: str

class ChatRequest(BaseModel):
    model: str
    messages: list[ChatMessage]
    temperature: Optional[float] = 0.7
    stream: Optional[bool] = False

class ChatResponse(BaseModel):
    id: str
    object: str
    created: int
    model: str
    choices: list[dict]
    usage: Optional[dict] = None

# === Endpoints ===
@app.get("/")
async def root():
    return {"message": "Magic Brain API", "docs": "/docs", "health": "/health"}

@app.get("/health")
async def health():
    return {"status": "ok"}

@app.post("/process")
async def process_endpoint(req: ProcessRequest):
    logging.info(f"Request: user={req.user_id}, text={req.text[:40]!r}")
    try:
        from agents.main.orchestrator import MagicBrain
        brain = MagicBrain()
        result = await brain.process(
            user_query=req.text, 
            user_id=req.user_id, 
            force_mode=req.force_mode, 
            force_agent=req.force_agent
        )
        logging.info(f"Response: tag={result.get('tag')}")
        return result
    except Exception as e:
        logging.error(f"Error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/models")
async def list_models():
    try:
        import httpx
        async with httpx.AsyncClient(timeout=5) as c:
            r = await c.get("http://localhost:11434/api/tags")
            models = r.json().get("models", [])
            return {"local": [m["name"] for m in models], "cloud": ["openrouter:auto"]}
    except Exception as e:
        return {"local": ["qwen2.5:3b"], "cloud": ["openrouter:auto"], "warning": str(e)}

# === OpenAI-compatible endpoints for WebUI ===
@app.post("/v1/chat/completions", response_model=ChatResponse)
async def openai_chat(req: ChatRequest):
    logging.info(f"OpenAI endpoint: model={req.model}, messages={len(req.messages)}")
    try:
        user_msg = next((m.content for m in reversed(req.messages) if m.role == "user"), "")
        force_tools = "agent" in (req.model or "").lower()
        
        from agents.main.orchestrator import MagicBrain
        brain = MagicBrain()
        result = await brain.process(
            user_query=user_msg, 
            user_id=9999, 
            force_mode="tools" if force_tools else None, 
            force_agent=force_tools
        )
        
        return ChatResponse(
            id=f"mb-{int(time.time())}",
            object="chat.completion",
            created=int(time.time()),
            model=req.model or "magic-brain",
            choices=[{
                "index": 0, 
                "message": {"role": "assistant", "content": result.get("reply", "")}, 
                "finish_reason": "stop"
            }],
            usage={"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}
        )
    except Exception as e:
        logging.error(f"OpenAI endpoint error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/v1/models")
async def openai_models():
    try:
        import httpx
        async with httpx.AsyncClient(timeout=5) as c:
            r = await c.get("http://localhost:11434/api/tags")
            ollama = r.json().get("models", [])
        models = [{"id": m["name"], "object": "model", "owned_by": "ollama"} for m in ollama]
        models.append({"id": "magic-brain:agent", "object": "model", "owned_by": "magic-brain"})
        return {"object": "list", "data": models}
    except Exception:
        return {"object": "list", "data": [
            {"id": "qwen2.5:3b", "object": "model", "owned_by": "ollama"},
            {"id": "magic-brain:agent", "object": "model", "owned_by": "magic-brain"}
        ]}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
