#!/bin/bash
set -e
export PATH="$HOME/.local/bin:$PATH"
BASE=~/magic-brain

echo "════════════════════════════════════════"
echo "📋 LOGS: Последние 10 минут"
echo "════════════════════════════════════════"
echo "Время: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# === 1. API LOGS ===
echo "🔹 [API] /tmp/api.log"
echo "────────────────────────────────────────"
if [ -f /tmp/api.log ]; then
    tail -40 /tmp/api.log | grep -E "process|openrouter|cloud|rag|error|WARNING|POST" || tail -20 /tmp/api.log
else
    echo "⚠️ Не найден"
fi
echo ""

# === 2. BOT LOGS ===
echo "🔹 [BOT] /tmp/bot.log"
echo "────────────────────────────────────────"
if [ -f /tmp/bot.log ]; then
    tail -20 /tmp/bot.log | grep -E "INFO|ERROR|sendMessage|process" || tail -10 /tmp/bot.log
else
    echo "⚠️ Не найден"
fi
echo ""

# === 3. RAG DATA (упрощённо) ===
echo "🔹 [RAG] Последние записи в Qdrant"
echo "────────────────────────────────────────"
python3 << 'PY'
import sys, os
from pathlib import Path
BASE = Path.home() / "magic-brain"
sys.path.insert(0, str(BASE))
os.environ.setdefault("QDRANT_HOST", "localhost")
os.environ.setdefault("QDRANT_PORT", "6333")

try:
    from rag.store.qdrant_client import RAGStore
    store = RAGStore()
    # Прямой доступ к клиенту
    client = store.store if hasattr(store, 'store') else store
    results, _ = client.qdrant.scroll(
        collection_name=store.collection,
        limit=8,
        with_payload=True,
        with_vectors=False
    )
    print(f"📊 Показываю {len(results)} последних записей:\n")
    for i, pt in enumerate(reversed(results), 1):
        p = pt.payload or {}
        txt = (p.get("text") or p.get("meta",{}).get("text") or "")[:70]
        uid = p.get("user_id", "?")
        role = p.get("role") or p.get("type") or "?"
        priv = p.get("privacy", "?")
        print(f"{i}. [{priv}] u:{uid} {role}: {txt}...")
except Exception as e:
    print(f"⚠️ Ошибка: {e}")
PY
echo ""

# === 4. VAULT STATUS ===
echo "🔹 [VAULT] Токены"
echo "────────────────────────────────────────"
VAULT=$BASE/data/vault/token_map.pkl
if [ -f "$VAULT" ]; then
    python3 -c "
import pickle
with open('$VAULT','rb') as f: v=pickle.load(f)
print(f'Записей: {len(v)}')
for t,val in list(v.items())[-3:]:
    print(f'  {t[:35]}... → {val[:25]}...')
" 2>/dev/null || echo "⚠️ Не удалось прочитать"
else
    echo "⚠️ Пусто (токенизация не использовалась)"
fi
echo ""

# === 5. OPENROUTER CALLS ===
echo "🔹 [CLOUD] Запросы к OpenRouter"
echo "────────────────────────────────────────"
if [ -f /tmp/api.log ]; then
    grep -i "openrouter\|404\|401\|200.*POST" /tmp/api.log | tail -15 || echo "⚠️ Не найдено"
else
    echo "⚠️ /tmp/api.log не найден"
fi
echo ""

# === 6. PROCESSES ===
echo "🔹 [SYSTEM] Процессы"
echo "────────────────────────────────────────"
pgrep -a -f "uvicorn|bot.py|qdrant|ollama" 2>/dev/null || echo "⚠️ Нет"
echo ""

# === 7. ENV KEYS ===
echo "🔹 [CONFIG] Ключи (.env)"
echo "────────────────────────────────────────"
grep -E "^(OPENROUTER|TG_BOT|API)_.*=" $BASE/.env 2>/dev/null | sed 's/=.\{10,\}/=****/' || echo "⚠️ Не найдено"
echo ""

echo "════════════════════════════════════════"
echo "💡 Если видишь проблему — скинь этот вывод."
echo "════════════════════════════════════════"
