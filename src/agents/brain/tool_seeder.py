"""🌱 Сидер: авто-сканирование packs/*.py → БД + строгая валидация"""

import glob
import importlib
import logging
import os
import sys

PROJECT_SRC = os.path.expanduser("~/magic-brain-deploy/src")
sys.path.insert(0, PROJECT_SRC)
from agents.brain.tool_db import _get_conn, init_db, register_tool

REQUIRED_FIELDS = {"name", "func", "desc", "category"}


def validate_skill(s: dict, mod_name: str) -> bool:
    """Проверка обязательных полей и типов"""
    for f in REQUIRED_FIELDS:
        if f not in s or not s[f]:
            logging.warning(f"⚠️ {mod_name}: missing '{f}' in skill {s.get('name', '?')}")
            return False
    if not isinstance(s.get("params", {}), dict):
        logging.warning(f"⚠️ {mod_name}: 'params' must be dict in {s['name']}")
        return False
    return True


def seed_packs():
    """Сканирует packs/, валидирует, регистрирует"""
    packs_pattern = os.path.join(PROJECT_SRC, "agents/tools/packs/*.py")
    registered, skipped = 0, 0

    for pack_path in glob.glob(packs_pattern):
        if os.path.basename(pack_path).startswith("_"):
            continue
        mod_name = "agents.tools.packs." + os.path.basename(pack_path)[:-3]
        try:
            mod = importlib.import_module(mod_name)
            skills = getattr(mod, "__skills__", [])
            for s in skills:
                if not validate_skill(s, mod_name):
                    skipped += 1
                    continue
                register_tool(
                    name=s["name"],
                    desc=str(s["desc"])[:140],
                    params=s.get("params", {}),
                    func_path=f"{mod_name}:{s['name']}",
                    domain=s.get("domain", "local"),
                    category=str(s["category"]),
                    subcategory=str(s.get("subcategory", "")),
                    tags=s.get("tags", []),
                )
                registered += 1
            logging.info(f"✅ {mod_name}: {len(skills)} processed")
        except Exception as e:
            logging.warning(f"⚠️ {mod_name}: {e}")

    logging.info(f"📊 Seed: {registered} registered, {skipped} skipped")


def seed_categories():
    """Описания категорий для LLM-роутинга"""
    hints = {
        ("local", "filesystem"): "файлы: чтение, запись, поиск, директории",
        ("local", "system"): "система: диск, процессы, память, uptime, shell",
        ("local", "memory"): "память: запомнить/вспомнить ключ-значение",
        ("local", "version_control"): "git: статус, коммит, pull, push",
        ("local", "network"): "сеть: ping, веб-поиск, HTTP, порты",
        ("local", "code"): "код: Python, pip, выполнение скриптов",
        ("local", "meta"): "мета: установка навыков, управление агентом",
    }
    conn = _get_conn()
    for (domain, name), desc in hints.items():
        conn.execute(
            "INSERT OR REPLACE INTO categories (domain, name, description) VALUES (?, ?, ?)",
            (domain, name, desc),
        )
    conn.commit()
    conn.close()


if __name__ == "__main__":
    init_db()
    seed_packs()
    seed_categories()
    conn = _get_conn()
    total = conn.execute("SELECT count(*) FROM tools").fetchone()[0]
    routes = conn.execute(
        "SELECT DISTINCT domain||'/'||category||'/'||subcategory FROM tools ORDER BY 1"
    ).fetchall()
    print(f"📊 В БД: {total} инструментов")
    print("🗂️ Маршруты:")
    for r in routes:
        print(f"  • {r[0]}")
    conn.close()
