#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain

echo "[1/4] Проверка, что API слушает..."
curl -sf http://127.0.0.1:8000/health && echo "✅ API OK" || { echo "❌ API DOWN"; exit 1; }

echo "[2/4] Сырой ответ /ingest (без парсинга)..."
echo "--- RAW RESPONSE ---"
RAW=$(curl -s -w "\n=== HTTP_CODE: %{http_code} ===" -X POST http://127.0.0.1:8000/ingest \
  -F "text=Тестовый документ для RAG. Квантовые компьютеры используют кубиты для вычислений." \
  -F "privacy=HIGH")
echo "$RAW"
echo "--- END RAW ---"

echo "[3/4] Проверка лога API на ошибки..."
echo "--- /tmp/api.log (последние 20 строк) ---"
tail -20 /tmp/api.log 2>/dev/null || echo "Файл не найден"

echo "[4/4] Попытка фикса: явный Content-Type..."
FIXED=$(curl -s -X POST http://127.0.0.1:8000/ingest \
  -H "Expect:" \
  -F "text=Тест RAG ingest" \
  -F "privacy=HIGH")
echo "Ответ: $FIXED"

echo ""
echo "Если в сыром ответе есть 'Traceback' или 'Internal Server Error' — ошибка в коде."
echo "Если пустой ответ — проблема с multipart-парсингом."
echo "ЖДУ: вывод сырого ответа."
