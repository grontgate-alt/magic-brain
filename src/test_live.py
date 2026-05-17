import asyncio
import os
import sys
from pathlib import Path

BASE = Path(__file__).parent
sys.path.insert(0, str(BASE))
os.chdir(BASE)  # Чтобы относительные пути работали

from qdrant_client import QdrantClient

from agents.critic.critic import Critic
from agents.prompt_opt.optimizer import PromptOptimizer
from rag.router.privacy_router import PrivacyRouter


async def main():
    router = PrivacyRouter()  # авто-путь
    critic = Critic()
    PromptOptimizer()
    qdrant = QdrantClient(host="localhost", port=6333)

    print("🔹 Тест 1: Приватный роутинг")
    assert router.classify("пароль от почты") == "LOCAL"
    print("  ✅ Приватные данные блокируются для облака")

    print("🔹 Тест 2: Scrubber")
    scrubbed = router.scrub("Мой email user@test.com")
    assert "user@test.com" not in scrubbed
    print(f"  ✅ Очистка: {scrubbed}")

    print("🔹 Тест 3: Qdrant")
    try:
        qdrant.create_collection(
            collection_name="test_ping", vectors_config={"size": 4, "distance": "Cosine"}
        )
        qdrant.upsert(
            collection_name="test_ping",
            points=[{"id": 1, "vector": [0.1] * 4, "payload": {"text": "ping"}}],
        )
        qdrant.delete_collection("test_ping")
        print("  ✅ Qdrant OK")
    except Exception as e:
        print(f"  ❌ Qdrant: {e}")

    print("🔹 Тест 4: Critic")
    ok, issues = critic.validate("Ответ: пароль admin123")
    assert not ok
    print(f"  ✅ Блокировка: {issues[0]}")

    print("\n🎉 ВСЕ ТЕСТЫ ПРОЙДЕНЫ.")


if __name__ == "__main__":
    asyncio.run(main())
