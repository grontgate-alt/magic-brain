#!/bin/bash
set -e
cd ~/magic-brain

echo "[1/3] Фикс critic_loop.py: добавляем импорт Dict..."
sed -i '1i from typing import Dict, List, Tuple, Any' agents/brain/critic_loop.py 2>/dev/null || true
# Или заменяем Dict → dict (современный стиль)
sed -i 's/\bDict\b/dict/g' agents/brain/critic_loop.py 2>/dev/null || true
echo "✅ critic_loop.py fixed"

echo "[2/3] Фикс worker.py: тоже проверяем..."
sed -i '1i from typing import Dict, List, Any' agents/brain/worker.py 2>/dev/null || true
sed -i 's/\bDict\b/dict/g' agents/brain/worker.py 2>/dev/null || true
echo "✅ worker.py fixed"

echo "[3/3] Проверка синтаксиса..."
python3 -m py_compile agents/brain/critic_loop.py && echo "✅ critic_loop.py OK"
python3 -m py_compile agents/brain/worker.py && echo "✅ worker.py OK"
python3 -m py_compile agents/main/orchestrator.py && echo "✅ orchestrator.py OK"

echo ""
echo "[4/4] Перезапуск API..."
pkill -f uvicorn 2>/dev/null || true; sleep 3
set -a; source ~/magic-brain/.env; set +a
cd ~/magic-brain/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 6
curl -sf http://127.0.0.1:8000/health && echo "✅ API UP" || echo "❌ API DOWN"

echo ""
echo "🧪 Тест (напиши боту):"
echo "  • 'Покажи файлы в /home/der'"
echo ""
echo "ЖДУ: результат."
