#!/bin/bash
set -e
echo "🚀 Magic Brain — Full Deployment"
echo "================================="

# Проверка прав
if [ "$EUID" -eq 0 ]; then 
  echo "❌ Не запускай от root. Запусти как обычный пользователь."
  exit 1
fi

# 1. Системные пакеты
echo "[1/8] Installing system packages..."
sudo apt update -qq && sudo apt install -y -qq python3-pip curl git docker.io >/dev/null

# 2. Python зависимости
echo "[2/8] Installing Python packages..."
pip3 install -q -r requirements.txt --user 2>/dev/null || pip3 install -q fastapi uvicorn pydantic httpx python-telegram-bot qdrant-client sentence-transformers ollama python-dotenv --user

# 3. Ollama
echo "[3/8] Setting up Ollama..."
if ! command -v ollama >/dev/null 2>&1; then
  curl -fsSL https://ollama.com/install.sh | sh
fi
sudo systemctl enable --now ollama 2>/dev/null || true
sleep 3
ollama list | grep -q qwen2.5:3b || ollama pull qwen2.5:3b

# 4. Docker сервисы
echo "[4/8] Starting Docker services..."
sudo docker compose -f docker/docker-compose.yml up -d >/dev/null 2>&1 || sudo docker-compose -f docker/docker-compose.yml up -d >/dev/null 2>&1
sleep 5

# 5. systemd сервисы
echo "[5/8] Installing systemd services..."
sudo cp systemd/magic-brain-api.service /etc/systemd/system/ 2>/dev/null || true
sudo systemctl daemon-reload
sudo systemctl enable --now magic-brain-api 2>/dev/null || true

# 6. .env файл
echo "[6/8] Setting up environment..."
if [ ! -f .env ]; then
  cp .env.example .env
  echo "⚠️  Edit .env with your actual keys (OPENROUTER_API_KEY, TG_BOT_TOKEN)"
fi

# 7. Права на скрипты
echo "[7/8] Fixing permissions..."
chmod +x deploy.sh scripts/*.sh 2>/dev/null || true

# 8. Health checks
echo "[8/8] Running health checks..."
sleep 8
API_OK=$(curl -sf --max-time 5 http://localhost:8000/health 2>/dev/null | grep -c '"status":"ok"' || echo 0)
OLLAMA_OK=$(curl -sf --max-time 5 http://localhost:11434/api/tags >/dev/null 2>&1 && echo 1 || echo 0)
QDRANT_OK=$(sudo docker ps 2>/dev/null | grep -c qdrant || echo 0)

echo ""
echo "📊 Status:"
[ "$API_OK" -ge 1 ] && echo "  ✅ API (port 8000)" || echo "  ❌ API"
[ "$OLLAMA_OK" = "1" ] && echo "  ✅ Ollama (port 11434)" || echo "  ❌ Ollama"
[ "$QDRANT_OK" -ge 1 ] && echo "  ✅ Qdrant (port 6333)" || echo "  ❌ Qdrant"

echo ""
if [ "$API_OK" -ge 1 ] && [ "$OLLAMA_OK" = "1" ] && [ "$QDRANT_OK" -ge 1 ]; then
  echo "🎉 Deployment successful!"
  echo "📡 API: http://localhost:8000"
  echo "🌐 WebUI: http://localhost:3000"
  echo "🔧 Edit .env for API keys, then: sudo systemctl restart magic-brain-api"
  exit 0
else
  echo "⚠️  Some services failed. Check logs:"
  echo "  • API: journalctl -u magic-brain-api -n 20"
  echo "  • Docker: docker compose -f docker/docker-compose.yml logs"
  exit 1
fi
