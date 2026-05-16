#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain
ENV=$BASE/.env

echo "[1/3] Очистка процессов..."
pkill -9 -f "uvicorn\|python3.*bot" 2>/dev/null || true
sleep 3

echo "[2/3] Загрузка .env..."
sed -i 's/\r$//' $ENV
set -a; source $ENV; set +a
echo "🔑 Ключ: ${OPENROUTER_API_KEY:0:15}..."

echo "[3/3] Запуск API (через python3 -m, игнорирует PATH)..."
cd $BASE/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 8

curl -sf http://127.0.0.1:8000/health > /dev/null && echo "✅ API UP" || { echo "❌ API DOWN"; tail -20 /tmp/api.log; exit 1; }

echo "🧪 Тест /process (рецепт борща, 60с)..."
RESP=$(curl -s -X POST http://127.0.0.1:8000/process \
  -H "Content-Type: application/json" --max-time 60 \
  -d '{"user_id":1,"text":"рецепт борща","task_type":"default"}')
echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'✅ mode:{d.get(\"privacy_mode\")} | reply:{d.get(\"reply\",\"\")[:90]}...')"
echo "ЖДУ: вывод."
