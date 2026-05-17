#!/usr/bin/env python3
"""
🧪 Magic Brain API — Comprehensive Test Suite
Запуск: python3 test_api_comprehensive.py
"""

import asyncio
import contextlib
import os
import sys
import time

import httpx

BASE_URL = "http://127.0.0.1:8000"
USER_ID = 9999  # тестовый пользователь


class Colors:
    GREEN = "\033[92m"
    RED = "\033[91m"
    YELLOW = "\033[93m"
    BLUE = "\033[94m"
    END = "\033[0m"
    BOLD = "\033[1m"


def log(msg: str, level: str = "info"):
    prefix = {
        "ok": f"{Colors.GREEN}✓{Colors.END}",
        "fail": f"{Colors.RED}✗{Colors.END}",
        "warn": f"{Colors.YELLOW}⚠{Colors.END}",
        "info": f"{Colors.BLUE}•{Colors.END}",
    }.get(level, "•")
    print(f"{prefix} {msg}")


async def api_post(endpoint: str, payload: dict, timeout: float = 30.0) -> dict:
    async with httpx.AsyncClient(timeout=timeout) as client:
        r = await client.post(f"{BASE_URL}{endpoint}", json=payload)
        return {
            "status": r.status_code,
            "data": r.json()
            if r.headers.get("content-type", "").startswith("application/json")
            else r.text,
            "time": r.elapsed.total_seconds(),
        }


async def test_health():
    log("Тест: /health", "info")
    r = (
        await api_post("/health", {})
        if False
        else (await httpx.AsyncClient().get(f"{BASE_URL}/health"))
    )
    async with httpx.AsyncClient() as c:
        r = await c.get(f"{BASE_URL}/health")
    ok = r.status_code == 200 and r.json().get("status") == "ok"
    log(
        f"/health: {r.status_code} {r.elapsed.total_seconds() * 1000:.0f}ms {'✅' if ok else '❌'}",
        "ok" if ok else "fail",
    )
    return ok


async def test_process_basic():
    log("Тест: /process — базовый запрос", "info")
    payload = {"user_id": USER_ID, "text": "привет, как дела?", "force_mode": None}
    r = await api_post("/process", payload)
    ok = r["status"] == 200 and "reply" in r["data"] and "tag" in r["data"]
    tag = r["data"].get("tag", "?") if isinstance(r["data"], dict) else "?"
    log(
        f"Базовый чат: {tag} | {r['time'] * 1000:.0f}ms {'✅' if ok else '❌'}",
        "ok" if ok else "fail",
    )
    return ok


async def test_modes():
    log("Тест: /process — все режимы force_mode", "info")
    modes = [None, "tools", "chat", "rag", "web"]
    results = []
    for mode in modes:
        payload = {"user_id": USER_ID, "text": "тест режима", "force_mode": mode}
        r = await api_post("/process", payload, timeout=45)
        tag = r["data"].get("tag", "?") if isinstance(r["data"], dict) else "?"
        model = r["data"].get("model_used", "?") if isinstance(r["data"], dict) else "?"
        ok = r["status"] == 200 and "reply" in (r["data"] if isinstance(r["data"], dict) else {})
        results.append((mode, ok, tag, model, r["time"]))
        log(
            f"  force_mode={mode!r}: {tag} ({model}) {r['time'] * 1000:.0f}ms {'✅' if ok else '❌'}",
            "ok" if ok else "fail",
        )
    return all(r[1] for r in results)


async def test_agent_tasks():
    log("Тест: агент — файловые операции", "info")
    tasks = [
        ("Покажи файлы в /home/der", "list_directory"),
        ("Создай файл ~/api_test.txt и запиши туда: тест агента", "write_file"),
        ("Прочитай файл ~/api_test.txt", "read_file"),
    ]
    results = []
    for query, _expected_tool in tasks:
        payload = {"user_id": USER_ID, "text": query, "force_mode": "tools"}
        r = await api_post("/process", payload, timeout=45)
        tag = r["data"].get("tag", "?") if isinstance(r["data"], dict) else "?"
        reply = r["data"].get("reply", "") if isinstance(r["data"], dict) else ""
        # Проверяем, что агент сработал (не облачный чат)
        is_agent = "[🛠️" in tag or "agent" in (
            r["data"].get("model_used", "") if isinstance(r["data"], dict) else ""
        )
        ok = r["status"] == 200 and is_agent
        results.append((query[:40], ok, tag, reply[:60]))
        log(f"  {query[:40]}: {tag} {'✅' if ok else '❌'}", "ok" if ok else "fail")
    # Очистка тестового файла
    with contextlib.suppress(BaseException):
        os.remove(os.path.expanduser("~/api_test.txt"))
    return all(r[1] for r in results)


async def test_privacy_routing():
    log("Тест: приватность — LOCAL vs CLOUD", "info")
    # Запрос без чувствительных данных → может быть LOCAL
    q1 = {"user_id": USER_ID, "text": "расскажи анекдот про программистов", "force_mode": None}
    r1 = await api_post("/process", q1)
    pm1 = r1["data"].get("privacy_mode", "?") if isinstance(r1["data"], dict) else "?"

    # Запрос с токеном → должен быть CLOUD + scrubbing
    q2 = {
        "user_id": USER_ID,
        "text": "мой API ключ sk-1234567890abcdef, что с ним делать?",
        "force_mode": None,
    }
    r2 = await api_post("/process", q2)
    pm2 = r2["data"].get("privacy_mode", "?") if isinstance(r2["data"], dict) else "?"

    ok = r1["status"] == 200 and r2["status"] == 200
    log(f"  Обычный запрос: privacy={pm1} {'✅' if ok else '❌'}", "ok" if ok else "fail")
    log(
        f"  С токеном: privacy={pm2} (ожидается CLOUD) {'✅' if pm2 == 'CLOUD' else '⚠️'}",
        "ok" if pm2 == "CLOUD" else "warn",
    )
    return ok


async def test_edge_cases():
    log("Тест: граничные случаи", "info")
    cases = [
        ("", "пустой запрос"),
        ("!" * 5000, "очень длинный запрос"),
        ("{[<@#$%^&*()]}>", "спецсимволы"),
        ("привет привет привет " * 100, "повторы"),
        ("", "пустой текст", {"user_id": USER_ID, "text": "", "force_mode": "tools"}),
    ]
    results = []
    for _i, case in enumerate(cases[:4]):  # пропускаем дубликат
        query, desc = case[:2]
        payload = (
            {"user_id": USER_ID, "text": query, "force_mode": None} if len(case) == 2 else case[2]
        )
        try:
            r = await api_post("/process", payload, timeout=60)
            ok = r["status"] in (200, 400, 422)  # 4xx — валидная обработка ошибки
            results.append(ok)
            log(
                f"  {desc}: {r['status']} {r['time'] * 1000:.0f}ms {'✅' if ok else '❌'}",
                "ok" if ok else "fail",
            )
        except Exception as e:
            log(f"  {desc}: ❌ exception: {e}", "fail")
            results.append(False)
    return all(results)


async def test_performance():
    log("Тест: производительность (5 последовательных запросов)", "info")
    times = []
    for i in range(5):
        payload = {"user_id": USER_ID, "text": f"тест {i + 1}", "force_mode": "chat"}
        start = time.time()
        r = await api_post("/process", payload, timeout=30)
        elapsed = time.time() - start
        times.append(elapsed)
        tag = r["data"].get("tag", "?") if isinstance(r["data"], dict) else "?"
        log(f"  Запрос {i + 1}: {elapsed * 1000:.0f}ms {tag}", "info")
    avg = sum(times) / len(times)
    p95 = sorted(times)[int(len(times) * 0.95)] if len(times) > 1 else times[0]
    ok = avg < 15  # средний < 15с
    log(
        f"  Среднее: {avg * 1000:.0f}ms, P95: {p95 * 1000:.0f}ms {'✅' if ok else '⚠️ медленно'}",
        "ok" if ok else "warn",
    )
    return ok


async def test_models_endpoint():
    log("Тест: /models — список моделей", "info")
    async with httpx.AsyncClient() as c:
        r = await c.get(f"{BASE_URL}/models")
    ok = r.status_code == 200 and "local" in r.json() and "cloud" in r.json()
    data = r.json() if ok else {}
    log(
        f"  Локальных: {len(data.get('local', []))}, облачных: {len(data.get('cloud', []))} {'✅' if ok else '❌'}",
        "ok" if ok else "fail",
    )
    return ok


async def run_all_tests():
    print(f"\n{Colors.BOLD}🧪 Magic Brain API — Comprehensive Test Suite{Colors.END}")
    print(f"Target: {BASE_URL}, User ID: {USER_ID}\n")

    tests = [
        ("Health check", test_health),
        ("Basic process", test_process_basic),
        ("All force_modes", test_modes),
        ("Agent tasks", test_agent_tasks),
        ("Privacy routing", test_privacy_routing),
        ("Edge cases", test_edge_cases),
        ("Performance", test_performance),
        ("Models endpoint", test_models_endpoint),
    ]

    results = []
    for name, func in tests:
        print(f"\n{Colors.BOLD}─── {name} ───{Colors.END}")
        try:
            ok = await func()
            results.append((name, ok))
        except Exception as e:
            log(f"❌ Test crashed: {e}", "fail")
            results.append((name, False))
        await asyncio.sleep(1)  # пауза между тестами

    # Итог
    print(f"\n{Colors.BOLD}{'=' * 60}{Colors.END}")
    print(f"{Colors.BOLD}📊 ИТОГИ:{Colors.END}")
    passed = sum(1 for _, ok in results if ok)
    total = len(results)
    for name, ok in results:
        symbol = f"{Colors.GREEN}✅{Colors.END}" if ok else f"{Colors.RED}❌{Colors.END}"
        print(f"  {symbol} {name}")
    print(f"\n{Colors.BOLD}Пройдено: {passed}/{total} тестов{Colors.END}")
    if passed == total:
        print(f"{Colors.GREEN}🎉 Все тесты пройдены! Система готова.{Colors.END}")
    elif passed >= total * 0.8:
        print(f"{Colors.YELLOW}⚠️ Большинство тестов пройдено. Проверь упавшие.{Colors.END}")
    else:
        print(f"{Colors.RED}❌ Много неудач. Требуется диагностика.{Colors.END}")
    print(f"{Colors.BOLD}{'=' * 60}{Colors.END}\n")
    return passed == total


if __name__ == "__main__":
    success = asyncio.run(run_all_tests())
    sys.exit(0 if success else 1)
