#!/bin/bash
set -e
cd ~/magic-brain

echo "=== [1/5] Ollama: systemd автозапуск ==="
# Официальный установщик настраивает systemd сервис автоматически
if ! command -v ollama >/dev/null; then
    echo "⏳ Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
fi
# Проверяем/включаем сервис
sudo systemctl enable ollama 2>/dev/null || true
sudo systemctl start ollama 2>/dev/null || true
# Ждём готовности
sleep 3
curl -sf -m 5 http://localhost:11434/api/tags >/dev/null && echo "✅ Ollama: автозапуск настроен" || echo "⚠️ Ollama: проверь установку"

echo ""
echo "=== [2/5] Qdrant: Docker с авто-рестартом ==="
if command -v docker >/dev/null; then
    # Если контейнер есть — обновляем политику рестарта
    docker update --restart=always qdrant 2>/dev/null || true
    # Если нет — создаём с автозапуском
    if ! docker ps -a --format '{{.Names}}' | grep -q '^qdrant$'; then
        docker run -d \
            --name qdrant \
            --restart=always \
            -p 6333:6333 -p 6334:6334 \
            -v ~/qdrant_storage:/qdrant/storage \
            qdrant/qdrant:latest
    fi
    docker start qdrant 2>/dev/null || true
    sleep 2
    curl -sf -m 3 http://localhost:6333/ >/dev/null && echo "✅ Qdrant: автозапуск настроен" || echo "⚠️ Qdrant: проверь Docker"
else
    echo "⚠️ Docker not found — Qdrant автозапуск пропущен"
fi

echo ""
echo "=== [3/5] API: systemd сервис ==="
cat << 'SERVICE' | sudo tee /etc/systemd/system/magic-brain-api.service > /dev/null
[Unit]
Description=Magic Brain API
After=network-online.target ollama.service docker.service
Wants=network-online.target

[Service]
Type=simple
User=der
WorkingDirectory=/home/der/magic-brain/interfaces/api
Environment="PATH=/home/der/.local/bin:/usr/local/bin:/usr/bin:/bin"
Environment="QDRANT_HOST=localhost"
Environment="OPENROUTER_API_KEY=${OPENROUTER_API_KEY:-}"
ExecStart=/home/der/.local/bin/python3 -m uvicorn main:app --host 0.0.0.0 --port 8000
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE

sudo systemctl daemon-reload
sudo systemctl enable magic-brain-api.service
sudo systemctl start magic-brain-api.service
sleep 3
curl -sf http://localhost:8000/health >/dev/null && echo "✅ API: systemd сервис активен" || echo "⚠️ API: проверь логи (journalctl -u magic-brain-api)"

echo ""
echo "=== [4/5] Bot: опционально (требует VPN) ==="
# Создаём скрипт, но НЕ включаем автозапуск по умолчанию (бот нужен не всегда)
cat << 'BOTSCRIPT' > ~/magic-brain/start-bot.sh
#!/bin/bash
# Запуск бота (требует активного VPN для Telegram)
cd ~/magic-brain/interfaces/telegram
exec python3 bot.py
BOTSCRIPT
chmod +x ~/magic-brain/start-bot.sh

# Создаём systemd сервис, но в disabled состоянии
cat << 'SERVICE' | sudo tee /etc/systemd/system/magic-brain-bot.service > /dev/null
[Unit]
Description=Magic Brain Telegram Bot
After=network-online.target magic-brain-api.service
Wants=network-online.target

[Service]
Type=simple
User=der
WorkingDirectory=/home/der/magic-brain/interfaces/telegram
Environment="PATH=/home/der/.local/bin:/usr/local/bin:/usr/bin:/bin"
Environment="TG_BOT_TOKEN=${TG_BOT_TOKEN:-}"
Environment="HTTPS_PROXY=${HTTPS_PROXY:-}"
ExecStart=/home/der/.local/bin/python3 bot.py
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE

sudo systemctl daemon-reload
# НЕ включаем: sudo systemctl enable magic-brain-bot.service
echo "✅ Bot: скрипт готов (~/magic-brain/start-bot.sh)"
echo "   Чтобы включить автозапуск бота: sudo systemctl enable --now magic-brain-bot.service"

echo ""
echo "=== [5/5] Финальная проверка ==="
echo ""
echo "🔹 Сервисы:"
systemctl is-active ollama 2>/dev/null && echo "  ✅ Ollama" || echo "  ❌ Ollama"
systemctl is-active magic-brain-api 2>/dev/null && echo "  ✅ API" || echo "  ❌ API"
docker ps --format '{{.Names}}\t{{.Status}}' 2>/dev/null | grep qdrant && echo "  ✅ Qdrant" || echo "  ⚠️ Qdrant"

echo ""
echo "🔹 Порты:"
ss -tlnp 2>/dev/null | grep -E ':11434|:6333|:8000' | awk '{print "  ✅ " $4}' || echo "  ⚠️ Порты не слушают"

echo ""
echo "🔹 Тест агента:"
curl -s -X POST http://127.0.0.1:8000/process \
  -H "Content-Type: application/json" \
  -d '{"user_id": 999, "text": "Покажи файлы в /home/der", "force_mode": "tools"}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('  Tag:', d.get('tag')); print('  Reply:', d.get('reply','')[:80].replace('\n',' '))"

echo ""
echo "🎉 ГОТОВО!"
echo ""
echo "📋 Что настроено:"
echo "  • Ollama — автозапуск через systemd"
echo "  • Qdrant — автозапуск через Docker (--restart=always)"
echo "  • API — автозапуск через systemd (magic-brain-api.service)"
echo "  • Bot — скрипт ~/magic-brain/start-bot.sh (автозапуск опционально)"
echo ""
echo "🔄 После перезагрузки:"
echo "  1. Подожди 1-2 минуты"
echo "  2. Проверь: curl -sf http://localhost:8000/health"
echo "  3. Если бот нужен: sudo systemctl enable --now magic-brain-bot.service"
echo ""
echo "🛠️ Управление:"
echo "  • Перезапустить API: sudo systemctl restart magic-brain-api"
echo "  • Логи API: journalctl -u magic-brain-api -f"
echo "  • Остановить API: sudo systemctl stop magic-brain-api"
echo ""
echo "✅ Система полностью автономна."
