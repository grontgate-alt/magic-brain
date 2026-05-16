#!/bin/bash
set -e
BASE=~/magic-brain
ENV=$BASE/.env

echo "[1/3] Очистка процессов..."
pkill -9 -f "uvicorn main:app" 2>/dev/null || true
pkill -9 -f "python3.*bot.py" 2>/dev/null || true
sleep 3

echo "[2/3] Проверка и загрузка .env..."
# Убираем \r (Windows-переносы), которые ломают парсинг
sed -i 's/\r$//' $ENV
set -a; source $ENV; set +a
echo "🔑 Ключ в среде: ${OPENROUTER_API_KEY:0:18}... (длина: ${#OPENROUTER_API_KEY})"
[ ${#OPENROUTER_API_KEY} -lt 10 ] && { echo "❌ Ключ слишком короткий. Проверь .env"; exit 1; }

echo "[3/3] Запуск API с явным окружением..."
cd $BASE/interfaces/api
export OPENROUTER_API_KEY="$OPENROUTER_API_KEY"  # дублируем для надёжности
nohup uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 8

curl -sf http://127.0.0.1:8000/health > /dev/null && echo "✅ API UP" || { echo "❌ API DOWN"; tail -20 /tmp/api.log; exit 1; }

echo "🧪 Тест /process (рецепт борща, 60с)..."
RESP=$(curl -s -X POST http://127.0.0.1:8000/process \
  -H "Content-Type: application/json" --max-time 60 \
  -d '{"user_id":1,"text":"рецепт борща","task_type":"default"}')

echo "$RESP" | python3 -c "
import sys,json
try:
 d=json.load(sys.stdin)
 print(f'✅ mode:{d.get(\"privacy_mode\")} | reply:{d.get(\"reply\",\"\")[:80]}...')
except: print('⚠️ Таймаут или ошибка парсинга')
"
echo "ЖДУ: вывод. Если mode:CLOUD — ключ подхватился."
