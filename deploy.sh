#!/bin/bash
set -e
echo "🚀 Magic Brain — Full Deployment Script"
echo "======================================="

# 1. Системные зависимости
echo "[1/7] Installing system packages..."
sudo apt update && sudo apt install -y python3-pip curl git docker.io

# 2. Python зависимости
echo "[2/7] Installing Python packages..."
pip3 install -r requirements.txt --user

# 3. Ollama
echo "[3/7] Setting up Ollama..."
if ! command -v ollama >/dev/null; then
    curl -fsSL https://ollama.com/install.sh | sh
fi
sudo systemctl enable --now ollama
sleep 3
ollama pull qwen2.5:3b

# 4. Docker сервисы (Qdrant + WebUI)
echo "[4/7] Starting Docker services..."
sudo docker compose -f docker/docker-compose.yml up -d
sleep 5

# 5. systemd сервисы
echo "[5/7] Installing systemd services..."
sudo cp systemd/magic-brain-api.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now magic-brain-api

# 6. .env файл
echo "[6/7] Creating .env file..."
if [ ! -f .env ]; then
    cp .env.example .env
    echo "⚠️  Edit .env with your actual keys!"
fi

# 7. Финальная проверка
echo "[7/7] Running health checks..."
sleep 10
curl -sf http://localhost:8000/health >/dev/null && echo "✅ API" || echo "❌ API"
curl -sf http://localhost:11434/api/tags >/dev/null && echo "✅ Ollama" || echo "❌ Ollama"
sudo docker ps | grep -q qdrant && echo "✅ Qdrant" || echo "❌ Qdrant"

echo ""
echo "🎉 Deployment complete!"
echo "📡 API: http://localhost:8000"
echo "🌐 WebUI: http://localhost:3000"
echo "📖 Docs: edit .env, then: sudo systemctl restart magic-brain-api"
