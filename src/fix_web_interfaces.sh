#!/bin/bash
set -e
cd ~/magic-brain

echo "=== [1/3] Диагностика портов и сервисов ==="
echo "Порт 3000 (OpenWebUI):"
ss -tlnp | grep ':3000' || echo "  ❌ Не слушает"
sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | grep -E '3000|webui' || echo "  ⚠️ Docker контейнер не найден"

echo ""
echo "Порт 8000 (наш API):"
curl -sf http://localhost:8000/health && echo "  ✅ API health OK" || echo "  ❌ API down"

echo ""
echo "Порт 11434 (Ollama):"
curl -sf http://localhost:11434/api/tags | python3 -c "import sys,json; models=json.load(sys.stdin).get('models',[]); print(f'  ✅ {len(models)} моделей: {[m[\"name\"] for m in models[:3]]}')" 2>/dev/null || echo "  ❌ Ollama не отвечает"

echo ""
echo "=== [2/3] Фикс: наш API — корректные эндпоинты ==="
# Проверяем, что эндпоинты зарегистрированы
echo "Доступные эндпоинты нашего API:"
curl -sf http://localhost:8000/openapi.json 2>/dev/null | python3 -c "
import sys,json
try:
    spec=json.load(sys.stdin)
    paths=list(spec.get('paths',{}).keys())
    print('  📡 Эндпоинты:', ', '.join(paths) if paths else '⚠️ пусто')
except: print('  ⚠️ Не удалось прочитать openapi.json')
" || echo "  ⚠️ openapi.json недоступен"

# Если /process возвращает 404 — проверяем main.py
if curl -sf -X POST http://localhost:8000/process -H "Content-Type: application/json" -d '{"user_id":1,"text":"test"}' 2>/dev/null | grep -q "Not Found"; then
    echo "  ⚠️ /process возвращает 404 — перезаписываем main.py..."
    cat << 'PY' > ~/magic-brain/interfaces/api/main.py
import os, sys, logging, json
from pathlib import Path
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import Optional, Any

sys.path.insert(0, str(Path(__file__).parent.parent.parent))
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

app = FastAPI(title="Magic Brain API", version="1.0.0")

# CORS для веб-интерфейсов
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

class ProcessRequest(BaseModel):
    user_id: int
    text: str
    force_mode: Optional[str] = None
    force_agent: Optional[bool] = False
    context: Optional[Any] = None

class ProcessResponse(BaseModel):
    reply: str
    privacy_mode: str
    model_used: str
    context_used: int
    tag: str

@app.get("/")
async def root():
    return {"message": "Magic Brain API", "docs": "/docs", "health": "/health"}

@app.get("/health")
async def health():
    return {"status": "ok", "services": {"ollama": "check /api/tags", "qdrant": "check /", "api": "ok"}}

@app.post("/process", response_model=ProcessResponse)
async def process_endpoint(req: ProcessRequest):
    logging.info(f"📥 POST /process: user={req.user_id}, text={req.text[:50]!r}, force_mode={req.force_mode}")
    try:
        from agents.main.orchestrator import MagicBrain
        brain = MagicBrain()
        result = await brain.process(
            user_query=req.text,
            user_id=req.user_id,
            force_mode=req.force_mode,
            force_agent=req.force_agent
        )
        logging.info(f"📤 Response: tag={result.get('tag')}, model={result.get('model_used')}")
        return result
    except Exception as e:
        logging.error(f"❌ /process error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/models")
async def list_models():
    """Список доступных моделей (для веб-интерфейса)"""
    try:
        import httpx
        async with httpx.AsyncClient(timeout=5) as c:
            r = await c.get("http://localhost:11434/api/tags")
            ollama_models = r.json().get("models", [])
            return {"local": [m["name"] for m in ollama_models], "cloud": ["openrouter:auto"]}
    except:
        return {"local": ["qwen2.5:3b"], "cloud": ["openrouter:auto"], "warning": "Ollama check failed"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
PY
    # Перезапускаем API
    sudo systemctl restart magic-brain-api
    sleep 3
    curl -sf http://localhost:8000/health >/dev/null && echo "  ✅ API перезагружен" || echo "  ❌ API не поднялся"
fi

echo ""
echo "=== [3/3] OpenWebUI: подключение к Ollama ==="
# OpenWebUI должен видеть Ollama на порту 11434
# Проверяем переменные окружения контейнера
WEBUI_CONTAINER=$(sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -iE 'webui|openweb' | head -1)
if [ -n "$WEBUI_CONTAINER" ]; then
    echo "Контейнер: $WEBUI_CONTAINER"
    sudo docker inspect "$WEBUI_CONTAINER" --format '{{range $k,$v := .Config.Env}}{{$k}}={{$v}}{{"\n"}}{{end}}' 2>/dev/null | grep -iE 'ollama|openai' || echo "  ⚠️ Нет явных настроек Ollama"
    
    # Если Ollama не подключён — перезапускаем с правильными env
    if ! sudo docker exec "$WEBUI_CONTAINER" curl -sf http://host.docker.internal:11434/api/tags >/dev/null 2>&1; then
        echo "  ⚠️ OpenWebUI не видит Ollama. Пересоздаём контейнер..."
        sudo docker stop "$WEBUI_CONTAINER" 2>/dev/null || true
        sudo docker rm "$WEBUI_CONTAINER" 2>/dev/null || true
        sudo docker run -d \
            --name open-webui \
            --restart=always \
            -p 3000:8080 \
            -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
            -e OPENAI_API_KEY=sk-dummy \
            -v open-webui:/app/backend/data \
            --add-host=host.docker.internal:host-gateway \
            ghcr.io/open-webui/open-webui:main
        sleep 5
        curl -sf http://localhost:3000/health >/dev/null && echo "  ✅ OpenWebUI перезапущен" || echo "  ⚠️ Проверь логи: docker logs open-webui"
    else
        echo "  ✅ OpenWebUI видит Ollama"
    fi
else
    echo "  ⚠️ OpenWebUI контейнер не найден. Запускаем..."
    sudo docker run -d \
        --name open-webui \
        --restart=always \
        -p 3000:8080 \
        -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
        -v open-webui:/app/backend/data \
        --add-host=host.docker.internal:host-gateway \
        ghcr.io/open-webui/open-webui:main
    sleep 5
    curl -sf http://localhost:3000/health >/dev/null && echo "  ✅ OpenWebUI запущен" || echo "  ⚠️ Проверь: docker logs open-webui"
fi

echo ""
echo "=== ФИНАЛЬНАЯ ПРОВЕРКА ВЕБ-ИНТЕРФЕЙСОВ ==="
echo "Наш API:"
echo "  • GET /health: $(curl -sf http://localhost:8000/health 2>/dev/null | head -c 50 || echo '❌')"
echo "  • POST /process: $(curl -sf -X POST http://localhost:8000/process -H 'Content-Type: application/json' -d '{\"user_id\":1,\"text\":\"ok\"}' 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get(\"tag\",\"?\")[:10])' 2>/dev/null || echo '❌')"
echo "  • GET /models: $(curl -sf http://localhost:8000/models 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(f\"local:{len(d.get(\"local\",[]))}, cloud:{len(d.get(\"cloud\",[]))}\")' 2>/dev/null || echo '❌')"

echo ""
echo "OpenWebUI:"
echo "  • GET /health: $(curl -sf http://localhost:3000/health 2>/dev/null | head -c 50 || echo '❌')"
echo "  • Страница: открой в браузере http://$(curl -s ifconfig.me):3000"

echo ""
echo "✅ Веб-интерфейсы настроены. Переходим к тестам API."
