"""
📁 Smart File Operations — один инструмент для всех файловых задач
Агент выбирает его, когда хочет работать с файлами естественным языком.
"""
import os, pathlib, logging

async def smart_file_op(query, ctx, uid, operation: str, path: str, content: str = "") -> str:
    """
    🎯 Единый интерфейс для файлов: create, read, update, delete, append
    • operation: "create" | "read" | "update" | "delete" | "append"
    • path: полный путь к файлу
    • content: текст для записи (для create/update/append)
    """
    try:
        p = pathlib.Path(path).expanduser()
        
        if operation == "create":
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(content, encoding="utf-8")
            return f"✅ Файл создан: {path} ({len(content)} байт)"
        
        elif operation == "read":
            if not p.exists(): return f"❌ Файл не найден: {path}"
            return p.read_text(encoding="utf-8")[:4000]
        
        elif operation == "update":
            if not p.exists(): return f"❌ Файл не найден: {path}"
            p.write_text(content, encoding="utf-8")
            return f"✅ Файл обновлён: {path}"
        
        elif operation == "append":
            p.parent.mkdir(parents=True, exist_ok=True)
            with p.open("a", encoding="utf-8") as f: f.write(content + "\n")
            return f"✅ Добавлено в файл: {path}"
        
        elif operation == "delete":
            if p.exists(): p.unlink()
            return f"✅ Файл удалён: {path}"
        
        return f"❌ Неизвестная операция: {operation}"
    except Exception as e:
        logging.error(f"smart_file_op error: {e}")
        return f"❌ Ошибка: {e}"

# Регистрируем с ОЧЕНЬ понятным описанием для роутера
__skills__ = [{
    "name": "smart_file_op",
    "desc": "📁 WORK WITH FILES: create, read, update, delete, append. Use when user asks to 'создай файл', 'запиши текст', 'прочитай лог', 'удали файл', 'добавь строку'. Params: operation (create|read|update|delete|append), path (full filepath), content (text to write).",
    "params": {
        "operation": {"type": "string", "enum": ["create", "read", "update", "delete", "append"], "desc": "Тип операции"},
        "path": {"type": "string", "desc": "Полный путь к файлу, например /home/der/file.txt"},
        "content": {"type": "string", "desc": "Текст для записи (для create/update/append)"}
    },
    "func": smart_file_op,
    "privacy": "LOCAL"
}]
