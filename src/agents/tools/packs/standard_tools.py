"""🛠️ Стандартные инструменты. Декларативные метаданные."""

import json
import pathlib
import ssl
import subprocess
import urllib.parse
import urllib.request


async def read_file(q, ctx, uid, path: str) -> str:
    p = pathlib.Path(path).expanduser()
    return p.read_text()[:4000] if p.exists() else f"❌ {path} not found"


async def write_file(q, ctx, uid, path: str, content: str) -> str:
    p = pathlib.Path(path).expanduser()
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content)
    return f"✅ Saved: {path}"


async def execute_bash(q, ctx, uid, command: str, timeout: int = 30) -> str:
    r = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=timeout)
    return (r.stdout + r.stderr).strip()[:2000]


async def web_search(q, ctx, uid, query: str, limit: int = 3) -> str:
    try:
        url = f"https://api.duckduckgo.com/?q={urllib.parse.quote(query)}&format=json"
        with urllib.request.urlopen(url, context=ssl._create_unverified_context(), timeout=5) as r:
            d = json.loads(r.read().decode())
            return d.get("Abstract", "")[:500] or "ℹ️ No result"
    except:
        return "❌ Search failed"


async def git_status(q, ctx, uid, repo_path: str = "/home/der") -> str:
    p = pathlib.Path(repo_path).expanduser()
    if not (p / ".git").exists():
        return f"❌ Not a git repo: {repo_path}"
    r = subprocess.run(
        ["git", "-C", str(p), "status", "--short"], capture_output=True, text=True, timeout=10
    )
    return r.stdout.strip() or "✅ Clean"


async def remember(q, ctx, uid, key: str, value: str) -> str:
    f = pathlib.Path(f"~/.magic-brain/memory/{uid}.json").expanduser()
    f.parent.mkdir(parents=True, exist_ok=True)
    m = json.loads(f.read_text()) if f.exists() else {}
    m[key] = value
    f.write_text(json.dumps(m))
    return f"✅ Saved {key}"


async def recall(q, ctx, uid, key: str) -> str:
    f = pathlib.Path(f"~/.magic-brain/memory/{uid}.json").expanduser()
    if not f.exists():
        return "❌ Memory empty"
    return json.loads(f.read_text()).get(key, f"❌ '{key}' not found")


__skills__ = [
    {
        "name": "read_file",
        "func": read_file,
        "desc": "📖 Чтение файла",
        "params": {"path": {}},
        "category": "filesystem",
        "subcategory": "files",
        "domain": "local",
    },
    {
        "name": "write_file",
        "func": write_file,
        "desc": "💾 Запись файла",
        "params": {"path": {}, "content": {}},
        "category": "filesystem",
        "subcategory": "files",
        "domain": "local",
    },
    {
        "name": "execute_bash",
        "func": execute_bash,
        "desc": "💻 Bash-команда",
        "params": {"command": {}, "timeout": {"default": 30}},
        "category": "system",
        "subcategory": "shell",
        "domain": "local",
    },
    {
        "name": "web_search",
        "func": web_search,
        "desc": "🔍 Веб-поиск",
        "params": {"query": {}, "limit": {"default": 3}},
        "category": "network",
        "subcategory": "web",
        "domain": "local",
    },
    {
        "name": "git_status",
        "func": git_status,
        "desc": "📦 Git статус",
        "params": {"repo_path": {"default": "/home/der"}},
        "category": "version_control",
        "subcategory": "git",
        "domain": "local",
    },
    {
        "name": "remember",
        "func": remember,
        "desc": "💾 Запомнить ключ",
        "params": {"key": {}, "value": {}},
        "category": "memory",
        "subcategory": "kv",
        "domain": "local",
    },
    {
        "name": "recall",
        "func": recall,
        "desc": "🔎 Вспомнить ключ",
        "params": {"key": {}},
        "category": "memory",
        "subcategory": "kv",
        "domain": "local",
    },
]
