#!/bin/bash
set -e
ENV_FILE=~/magic-brain/.env
echo "🔍 Текущие записи в .env (замаскировано):"
grep -i "OPENROUTER" $ENV_FILE 2>/dev/null | sed 's/\(sk-or-v1-\).\{10\}.*/\1**********/' || echo "Ключи не найдены"
echo ""
read -sp "🔑 Вставь ЕДИНСТВЕННЫЙ правильный ключ (начинается с sk-or-v1-): " NEW_KEY
echo ""
[[ ! "$NEW_KEY" =~ ^sk-or-v1- ]] && { echo "❌ Неверный формат."; exit 1; }
echo "✅ Перезаписываю .env только одним ключом..."
cat << ENV > $ENV_FILE
OPENROUTER_API_KEY=$NEW_KEY
OLLAMA_HOST=http://localhost:11434
QDRANT_HOST=localhost
QDRANT_PORT=6333
RAG_COLLECTION=magic_brain
PRIVACY_MODE=strict
ENV
chmod 600 $ENV_FILE
echo "🧪 Тест ключа..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST https://openrouter.ai/api/v1/chat/completions \
  -H "Authorization: Bearer $NEW_KEY" \
  -H "Content-Type: application/json" \
  -H "HTTP-Referer: http://localhost" \
  -H "X-Title: MagicBrain" \
  -d '{"model":"meta-llama/llama-3.2-1b-instruct:free","messages":[{"role":"user","content":"ping"}]}')
[ "$STATUS" = "200" ] && echo "✅ Ключ валиден" || { echo "❌ Ошибка HTTP $STATUS. Проверь ключ."; exit 1; }
echo "🔄 Перезапуск API..."
pkill -f "uvicorn main:app" 2>/dev/null || true
sleep 2
cd ~/magic-brain/interfaces/api
export OPENROUTER_API_KEY=$NEW_KEY
nohup uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 5
curl -sf http://localhost:8000/health && echo "✅ API запущен с новым ключом" || echo "⚠️ API не ответил"
echo "ЖДУ: OK или вывод ошибки."
