#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain

echo "════════════════════════════════════════"
echo "📋 LOGS: Последние 10 минут"
echo "════════════════════════════════════════"
echo "Время сейчас: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Отсекаем логи старше: $(date -d '10 minutes ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')"
echo ""

# === 1. API LOGS ===
echo "🔹 [API] /tmp/api.log (последние 50 строк + фильтр по времени)"
echo "────────────────────────────────────────"
if [ -f /tmp/api.log ]; then
    # Показываем последние 50 строк + ищем ключевые события
    tail -50 /tmp/api.log | grep -E "(POST|GET|process|openrouter|rag|error|INFO|WARNING)" || tail -20 /tmp/api.log
else
    echo "⚠️ Файл не найден"
fi
echo ""

# === 2. BOT LOGS ===
echo "🔹 [BOT] /tmp/bot.log (последние 30 строк)"
echo "────────────────────────────────────────"
if [ -f /tmp/bot.log ]; then
    tail -30 /tmp/bot.log | grep -E "(INFO|ERROR|sendMessage|getUpdates|process)" || tail -15 /tmp/bot.log
else
    echo "⚠️ Файл не найден"
fi
echo ""

# === 3. RAG OPERATIONS (Qdrant) ===
echo "🔹 [RAG] Проверка коллекции magic_brain"
echo "────────────────────────────────────────"
python3 << 'PY'
import sys, os
from pathlib import Path, datetime
BASE = Path.home() / "magic-brain"
sys.path.insert(0, str(BASE))
os.environ.setdefault("QDRANT_HOST", "localhost")
os.environ.setdefault("QDRANT_PORT", "6333")

try:
    from rag.store.qdrant_client import RAGStore
    store = RAGStore()
    
    # Показываем последние 10 записей
    from qdrant_client.http import models as qd
    results = store.store.qdrant.scroll(
        collection_name=store.collection,
        limit=10,
        with_payload=True,
        with_vectors=False
    )
    
    print(f"📊 Всего точек в коллекции: ~{len(results[0])}+ (показываем последние 10)")
    print("")
    for i, (point, _) in enumerate(reversed(results[0]), 1):
        payload = point.payload or {}
        text = payload.get("text", payload.get("meta",{}).get("text",""))[:80]
        user_id = payload.get("user_id", "?")
        role = payload.get("role", payload.get("type","?"))
        privacy = payload.get("privacy", "?")
        print(f"{i}. [{privacy}] user:{user_id} {role}: {text}...")
except Exception as e:
    print(f"⚠️ Не удалось получить данные из Qdrant: {e}")
PY
echo ""

# === 4. TOKEN VAULT STATUS ===
echo "🔹 [VAULT] Токенизация (data/vault/token_map.pkl)"
echo "────────────────────────────────────────"
VAULT_FILE=$BASE/data/vault/token_map.pkl
if [ -f "$VAULT_FILE" ]; then
    python3 << PY
import pickle, sys
from pathlib import Path
try:
    with open("$VAULT_FILE", "rb") as f:
        vault = pickle.load(f)
    print(f"📦 Записей в хранилище: {len(vault)}")
    if vault:
        print("Последние 5 токенов:")
        for i, (t, v) in enumerate(list(vault.items())[-5:], 1):
            print(f"  {i}. {t[:40]}... → {v[:30]}...")
except Exception as e:
    print(f"⚠️ Ошибка чтения: {e}")
PY
else
    echo "⚠️ Файл не найден (токенизация ещё не использовалась)"
fi
echo ""

# === 5. OPENROUTER REQUESTS (из api.log) ===
echo "🔹 [CLOUD] Запросы к OpenRouter (из api.log)"
echo "────────────────────────────────────────"
if [ -f /tmp/api.log ]; then
    grep -i "openrouter\|cloud\|404\|401\|200" /tmp/api.log | tail -20 || echo "⚠️ Не найдено"
else
    echo "⚠️ /tmp/api.log не найден"
fi
echo ""

# === 6. ТЕКУЩИЕ ПРОЦЕССЫ ===
echo "🔹 [SYSTEM] Активные процессы"
echo "────────────────────────────────────────"
ps aux | grep -E "(uvicorn|bot.py|qdrant|ollama)" | grep -v grep || echo "⚠️ Нет процессов"
echo ""

# === 7. .ENV STATUS ===
echo "🔹 [CONFIG] Ключи в .env (маскированные)"
echo "────────────────────────────────────────"
grep -E "^(OPENROUTER|TG_BOT|API)_.*=" $BASE/.env | sed -E 's/(KEY|TOKEN)=.*/\1=****/g' || echo "⚠️ Не найдено"
echo ""

echo "════════════════════════════════════════"
echo "💡 Подсказка: если хочешь увидеть конкретный тип логов — напиши:"
echo "   • 'logs api' — только API"
echo "   • 'logs bot' — только бот"  
echo "   • 'logs rag' — только RAG операции"
echo "   • 'logs vault' — только токенизация"
echo "════════════════════════════════════════"
