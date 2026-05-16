#!/bin/bash
BACKUP_DIR="${1:-~/magic-brain-backups}"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
BACKUP_NAME="magic-brain-$TIMESTAMP"

mkdir -p "$BACKUP_DIR"
echo "📦 Creating backup: $BACKUP_NAME"

# Архивируем весь deploy-репозиторий
cd ~/magic-brain-deploy
tar czf "$BACKUP_DIR/$BACKUP_NAME.tar.gz" . \
  --exclude='.git' --exclude='backups' --exclude='*.log' 2>/dev/null

echo "✅ Saved: $BACKUP_DIR/$BACKUP_NAME.tar.gz"
echo "📦 Size: $(du -h "$BACKUP_DIR/$BACKUP_NAME.tar.gz" | cut -f1)"
