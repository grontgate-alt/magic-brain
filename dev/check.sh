#!/bin/bash
set -e
cd "$(dirname "$0")/.."
echo "🔍 1. Python Syntax..."
find src/ -name "*.py" -exec python3 -m py_compile {} \; 2>&1 | grep -i "error" && exit 1 || echo "✅ Syntax OK"

echo "🧹 2. Ruff Format & Fix..."
ruff format src/ --quiet 2>/dev/null || true
ruff check src/ --fix --quiet 2>/dev/null || echo "⚠️ Lint warnings"

echo "📦 3. Import Chain..."
cd src && python3 -c "
import agents.brain.tool_db
import agents.brain.tool_seeder
import agents.brain.planner
import agents.brain.registry
import agents.brain.agent_loop
import agents.skills.schema
print('✅ All imports resolved')
" 2>&1

echo "📊 4. Git Status..."
cd .. && git status --short
echo "🟢 Ready for commit & test"
