"""🗄️ Иерархическая БД инструментов: domain/category/subcategory"""
import sqlite3, json, os, logging
from pathlib import Path
from typing import List, Dict, Optional

DB_PATH = Path(os.path.expanduser("~/.magic-brain/tools.db"))

def _get_conn() -> sqlite3.Connection:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn

def init_db():
    conn = _get_conn()
    conn.execute("""CREATE TABLE IF NOT EXISTS tools (
        name TEXT PRIMARY KEY, domain TEXT, category TEXT, subcategory TEXT,
        description TEXT, params_json TEXT, func_path TEXT, tags TEXT
    )""")
    conn.execute("""CREATE TABLE IF NOT EXISTS categories (
        id INTEGER PRIMARY KEY, domain TEXT, name TEXT, description TEXT,
        UNIQUE(domain, name)
    )""")
    conn.commit()
    conn.close()

def register_tool(name: str, desc: str, params: dict, func_path: str,
                  domain: str = "local", category: str = "general",
                  subcategory: str = "", tags: list = None):
    conn = _get_conn()
    conn.execute("""INSERT OR REPLACE INTO tools
        (name, domain, category, subcategory, description, params_json, func_path, tags)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
        (name, domain, category, subcategory, desc, json.dumps(params), func_path, json.dumps(tags or [])))
    conn.commit()
    conn.close()

def get_routes() -> List[tuple]:
    """Возвращает (route, description) через JOIN с categories"""
    conn = _get_conn()
    rows = conn.execute("""
        SELECT DISTINCT 
            t.domain || '/' || t.category || '/' || t.subcategory as route,
            COALESCE(c.description, 'инструменты') as desc
        FROM tools t
        LEFT JOIN categories c ON t.category = c.name AND c.domain = t.domain
        ORDER BY route
    """).fetchall()
    conn.close()
    return [(r[0], r[1]) for r in rows]

def get_tools_by_route(route: str) -> List[dict]:
    try: d, c, sc = route.split('/')
    except ValueError: return []
    conn = _get_conn()
    rows = conn.execute(
        "SELECT name, description, params_json FROM tools WHERE domain=? AND category=? AND subcategory=?",
        (d, c, sc)
    ).fetchall()
    conn.close()
    return [{"name": r["name"], "desc": r["description"], "params": json.loads(r["params_json"])} for r in rows]
