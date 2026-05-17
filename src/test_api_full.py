#!/usr/bin/env python3
"""
🧪 Magic Brain API — Full Test Suite
Все режимы, задачи, нюансы, граничные случаи
Запуск: python3 ~/magic-brain/test_api_full.py
"""

import asyncio
import contextlib
import os
import sys

import httpx

BASE = "http://127.0.0.1:8000"
UID = 9999
TIMEOUT = 45


class T:
    G, R, Y, B = "\033[92m", "\033[91m", "\033[93m", "\033[94m"
    E = "\033[0m"

    @staticmethod
    def log(ok: bool, name: str, detail: str = ""):
        sym = f"{T.G}✓{T.E}" if ok else f"{T.R}✗{T.E}"
        print(f"{sym} {name}" + (f" | {detail}" if detail else ""))


async def post(ep: str, data: dict, t: float = TIMEOUT) -> dict:
    async with httpx.AsyncClient(timeout=t) as c:
        r = await c.post(f"{BASE}{ep}", json=data)
        return {
            "code": r.status_code,
            "data": r.json() if "application/json" in r.headers.get("content-type", "") else r.text,
            "time": r.elapsed.total_seconds(),
        }


async def test_health():
    async with httpx.AsyncClient(timeout=5) as c:
        r = await c.get(f"{BASE}/health")
    ok = r.status_code == 200 and r.json().get("status") == "ok"
    T.log(ok, "Health check", f"{r.elapsed.total_seconds() * 1000:.0f}ms")
    return ok


async def test_basic_chat():
    r = await post("/process", {"user_id": UID, "text": "привет, как дела?"})
    ok = r["code"] == 200 and "reply" in r["data"] and "tag" in r["data"]
    tag = r["data"].get("tag", "?") if isinstance(r["data"], dict) else "?"
    T.log(ok, "Basic chat", f"{tag} | {r['time'] * 1000:.0f}ms")
    return ok


async def test_force_modes():
    modes = [None, "tools", "chat"]
    results = []
    for m in modes:
        r = await post("/process", {"user_id": UID, "text": "тест режима", "force_mode": m})
        ok = r["code"] == 200 and "reply" in (r["data"] if isinstance(r["data"], dict) else {})
        tag = r["data"].get("tag", "?") if isinstance(r["data"], dict) else "?"
        T.log(ok, f"force_mode={m!r}", f"{tag} | {r['time'] * 1000:.0f}ms")
        results.append(ok)
    return all(results)


async def test_agent_file_ops():
    tests = [
        ("Покажи файлы в /home/der", "list"),
        ("Создай файл ~/mb_test.txt и запиши: агент работает", "write"),
        ("Прочитай файл ~/mb_test.txt", "read"),
    ]
    results = []
    for q, exp in tests:
        r = await post("/process", {"user_id": UID, "text": q, "force_mode": "tools"}, t=60)
        tag = r["data"].get("tag", "?") if isinstance(r["data"], dict) else "?"
        is_agent = "[🛠️" in tag or "agent" in str(
            r["data"].get("model_used", "") if isinstance(r["data"], dict) else ""
        )
        ok = r["code"] == 200 and is_agent
        T.log(ok, f"Agent [{exp}]", f"{tag} | {r['time'] * 1000:.0f}ms")
        results.append(ok)
    with contextlib.suppress(BaseException):
        os.remove(os.path.expanduser("~/mb_test.txt"))
    return all(results)


async def test_privacy_routing():
    r1 = await post("/process", {"user_id": UID, "text": "расскажи анекдот"})
    pm1 = r1["data"].get("privacy_mode", "?") if isinstance(r1["data"], dict) else "?"
    r2 = await post("/process", {"user_id": UID, "text": "мой ключ sk-abc123, что делать?"})
    pm2 = r2["data"].get("privacy_mode", "?") if isinstance(r2["data"], dict) else "?"
    ok = r1["code"] == 200 and r2["code"] == 200
    T.log(ok, "Privacy routing", f"normal={pm1}, secret={pm2} (ожидается CLOUD)")
    T.log(pm2 == "CLOUD", "  → Scrubbing токенов", "" if pm2 == "CLOUD" else "⚠️ не сработал")
    return ok


async def test_edge_cases():
    cases = [
        ("", "пустой"),
        ("!" * 3000, "длинный"),
        ("{[<@#$%^&*()]}>", "спецсимволы"),
        ("привет " * 200, "повторы"),
    ]
    results = []
    for q, desc in cases:
        r = await post("/process", {"user_id": UID, "text": q}, t=60)
        ok = r["code"] in (200, 400, 422)
        T.log(ok, f"Edge [{desc}]", f"{r['code']} | {r['time'] * 1000:.0f}ms")
        results.append(ok)
    return all(results)


async def test_openai_endpoint():
    # Тест /v1/models
    async with httpx.AsyncClient(timeout=10) as c:
        r = await c.get(f"{BASE}/v1/models")
    ok1 = r.status_code == 200 and "magic-brain:agent" in str(r.json())
    T.log(ok1, "OpenAI /v1/models", f"{'✅ agent found' if ok1 else '❌'}")

    # Тест /v1/chat/completions
    payload = {"model": "magic-brain:agent", "messages": [{"role": "user", "content": "ok"}]}
    r2 = await post("/v1/chat/completions", payload, t=30)
    ok2 = r2["code"] == 200 and "choices" in (r2["data"] if isinstance(r2["data"], dict) else {})
    T.log(ok2, "OpenAI /v1/chat", f"{'✅ reply' if ok2 else '❌'} | {r2['time'] * 1000:.0f}ms")
    return ok1 and ok2


async def test_models_endpoint():
    async with httpx.AsyncClient(timeout=10) as c:
        r = await c.get(f"{BASE}/models")
    ok = r.status_code == 200 and "local" in r.json() and "cloud" in r.json()
    d = r.json() if ok else {}
    T.log(
        ok, "Models endpoint", f"local:{len(d.get('local', []))}, cloud:{len(d.get('cloud', []))}"
    )
    return ok


async def test_performance():
    times = []
    for i in range(3):
        r = await post("/process", {"user_id": UID, "text": f"perf {i}", "force_mode": "chat"})
        times.append(r["time"])
    avg = sum(times) / len(times)
    ok = avg < 20
    T.log(ok, "Performance", f"avg:{avg * 1000:.0f}ms, p95:{sorted(times)[-1] * 1000:.0f}ms")
    return ok


async def test_error_handling():
    async with httpx.AsyncClient(timeout=10) as c:
        r = await c.post(
            f"{BASE}/process", content="not json", headers={"Content-Type": "application/json"}
        )
    ok = r.status_code in (400, 422, 500)
    T.log(ok, "Error handling", f"invalid JSON → {r.status_code}")
    return ok


async def run_all():
    print(f"\n{T.B}🧪 Magic Brain API — Full Test Suite{T.E}\nЦель: {BASE}, UID: {UID}\n")
    tests = [
        ("Health", test_health),
        ("Basic chat", test_basic_chat),
        ("Force modes", test_force_modes),
        ("Agent file ops", test_agent_file_ops),
        ("Privacy routing", test_privacy_routing),
        ("Edge cases", test_edge_cases),
        ("OpenAI endpoint", test_openai_endpoint),
        ("Models endpoint", test_models_endpoint),
        ("Performance", test_performance),
        ("Error handling", test_error_handling),
    ]
    results = []
    for name, func in tests:
        print(f"{T.B}── {name} ──{T.E}")
        try:
            ok = await func()
            results.append((name, ok))
        except Exception as e:
            T.log(False, name, f"CRASH: {e}")
            results.append((name, False))
        await asyncio.sleep(1)

    print(f"\n{T.B}{'=' * 50}{T.E}")
    passed = sum(1 for _, ok in results if ok)
    for name, ok in results:
        sym = f"{T.G}✅{T.E}" if ok else f"{T.R}❌{T.E}"
        print(f"  {sym} {name}")
    print(f"\n{T.B}Итог: {passed}/{len(results)} тестов пройдены{T.E}")
    if passed == len(results):
        print(f"{T.G}🎉 Все тесты пройдены! Система готова к продакшену.{T.E}")
    elif passed >= len(results) * 0.8:
        print(f"{T.Y}⚠️ Большинство тестов ОК. Проверь упавшие.{T.E}")
    else:
        print(f"{T.R}❌ Много неудач. Требуется диагностика.{T.E}")
    print(f"{T.B}{'=' * 50}{T.E}\n")
    return passed == len(results)


if __name__ == "__main__":
    ok = asyncio.run(run_all())
    sys.exit(0 if ok else 1)
