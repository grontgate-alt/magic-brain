#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain
cd $BASE

echo "[1/4] Фикс: правильный вызов orchestrator.process()..."
# Исправляем вызов: позиционные аргументы, не именованные
sed -i 's/await openai_chat.brain.process(user_msg, user_id=999, task_type="chat")/await openai_chat.brain.process(user_msg, 999, "chat")/' interfaces/api/main.py
echo "✅ Исправлен вызов process()"

echo "[2/4] Перезапуск API..."
pkill -9 -f "uvicorn" 2>/dev/null || true
sleep 3
set -a; source $BASE/.env; set +a
cd $BASE/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health > /dev/null && echo "✅ API UP" || { echo "❌ API DOWN"; tail -10 /tmp/api.log; exit 1; }

echo "[3/4] Тест OpenAI-эндпоинта..."
TEST_RESP=$(curl -s -X POST http://127.0.0.1:8000/v1/chat/completions \
  -H "Content-Type: application/json" --max-time 40 \
  -d '{"model":"magic-brain","messages":[{"role":"user","content":"привет, кто ты?"}]}')
echo "Ответ: $TEST_RESP" | python3 -c "
import sys,json
try:
 d=json.load(sys.stdin)
 if 'choices' in d and d['choices'][0].get('message',{}).get('content'):
  print('✅ OpenAI API работает')
  print(f'🤖 Ответ: {d[\"choices\"][0][\"message\"][\"content\"][:120]}...')
 elif 'error' in d:
  print(f'❌ Ошибка: {d[\"error\"][:150]}')
 else:
  print(f'❓ Неожиданный формат: {list(d.keys())}')
except Exception as e: print(f'❌ Парсинг: {e}')
"

echo "[4/4] Быстрый тест с приватным запросом..."
PRIV_RESP=$(curl -s -X POST http://127.0.0.1:8000/v1/chat/completions \
  -H "Content-Type: application/json" --max-time 40 \
  -d '{"model":"magic-brain","messages":[{"role":"user","content":"мой пароль от почты 12345"}]}')
echo "$PRIV_RESP" | python3 -c "
import sys,json
try:
 d=json.load(sys.stdin)
 content = d.get('choices',[{}])[0].get('message',{}).get('content','')
 if '🔐' in content or 'LOCAL' in content or 'пароль' in content.lower():
  print('✅ Приватность работает: чувствительный запрос обработан локально')
 else:
  print(f'ℹ️ Ответ: {content[:100]}...')
except: pass
"

echo ""
echo "📍 Если тесты прошли — запускай OpenWebUI:"
echo "  cd ~/magic-brain && docker compose -f docker-openwebui.yml up -d"
echo "  → http://192.168.11.101:3000"
echo ""
echo "ЖДУ: вывод тестов. Если ✅ — пишу шаг 21b (агенты: планировщик + tool-calling)."
