#!/bin/bash
set -e
cd ~/magic-brain

# Простой фикс: регистрируем паки как "raw exec" без __skill__
python3 << 'PY'
import sys, os
sys.path.insert(0, '.')
from agents.tools.pack_manager import pack_mgr

# Принудительная адаптация
pack_mgr.sync()
adapted = pack_mgr.adapt()
print(f"📦 Адаптировано паков: {len(adapted)}")

# Сохраняем как готовые модули
for name, meta in list(adapted.items())[:50]:  # первые 50 для теста
    out = f"agents/tools/packs/{name}.py"
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, 'w') as f:
        f.write(meta["code"])
print(f"✅ Сохранено 50 инструментов в agents/tools/packs/")
PY

# Перезагружаем реестр
python3 -c "
import asyncio, sys; sys.path.insert(0, '.')
from agents.brain.registry import registry
asyncio.run(registry.reload())
"
