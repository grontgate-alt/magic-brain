"""
🛠️ Стандартные инструменты. Имена совпадают с тем, что LLM предсказывает естественно.
Никаких резолверов. Планировщик пишет write_file → registry находит write_file → выполняется.
"""
import os, pathlib, subprocess, logging

async def read_file(query, ctx, uid, path: str) -> str:
    p = pathlib.Path(path).expanduser()
    if not p.exists(): return f"❌ Файл не найден: {path}"
    return p.read_text(encoding="utf-8")[:4000]

async def write_file(query, ctx, uid, path: str, content: str) -> str:
    p = pathlib.Path(path).expanduser()
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content, encoding="utf-8")
    return f"✅ Файл сохранён: {path} ({len(content)} байт)"

async def execute_bash(query, ctx, uid, command: str, timeout: int = 30) -> str:
    try:
        res = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=timeout)
        out = (res.stdout + res.stderr).strip()
        return out[:3000] if out else "✅ Выполнено. Нет вывода."
    except Exception as e: return f"❌ Ошибка: {e}"

__skills__ = [
    {"name": "read_file", "desc": "📖 Чтение содержимого файла. Возвращает текст.",
     "params": {"path": {"type": "string", "desc": "Полный путь"}}, "func": read_file},
    {"name": "write_file", "desc": "💾 Создание или перезапись файла.",
     "params": {"path": {"type": "string", "desc": "Путь"}, "content": {"type": "string", "desc": "Текст"}}, "func": write_file},
    {"name": "execute_bash", "desc": "💻 Выполнение bash-команды в системе.",
     "params": {"command": {"type": "string"}, "timeout": {"type": "integer", "default": 30}}, "func": execute_bash}
]
