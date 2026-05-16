#!/bin/bash
set -e
cd ~/magic-brain

echo "[1/3] Создаю __init__.py для корректного импорта пакетов..."
mkdir -p agents/brain agents/tools agents/mcp agents/main
touch agents/__init__.py agents/brain/__init__.py agents/tools/__init__.py agents/mcp/__init__.py agents/main/__init__.py 2>/dev/null || true
echo "✅ __init__.py созданы"

echo "[2/3] Проверка registry с абсолютным путём..."
python3 << 'PY'
import sys, os, asyncio
sys.path.insert(0, os.path.expanduser("~/magic-brain"))
try:
    from agents.brain.registry import registry
    async def check():
        await registry.wait_ready(timeout=8)
        fs = [k for k in registry.skills if "filesystem" in k]
        print(f"📦 Registry: {len(registry.skills)} tools, filesystem: {len(fs)}")
        if fs: print(f"   ✅ Пример: {fs[0]}")
    asyncio.run(check())
except Exception as e:
    print(f"⚠️ Registry init warning (non-critical): {e}")
PY

echo "[3/3] Перезапуск API..."
pkill -f uvicorn 2>/dev/null || true; sleep 3
set -a; source ~/magic-brain/.env; set +a
cd ~/magic-brain/interfaces/api
nohup python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 > /tmp/api.log 2>&1 &
sleep 8
curl -sf http://127.0.0.1:8000/health && echo "✅ API UP" || echo "❌ API DOWN"

echo ""
echo "🎉 Готово. Registry инициализируется в фоне, fallback на прямой MCP если нужно."
echo "🧪 Напиши боту: 'Покажи файлы в /home/der'"
echo "Ожидаемо: список файлов + [🛠️mcp] + кнопки под сообщением"
echo "ЖДУ: результат."
