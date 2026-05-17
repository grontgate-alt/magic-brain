"""📁 Файловые операции"""
import pathlib
async def smart_file_op(q, ctx, uid, path: str, action: str = "read") -> str:
    p = pathlib.Path(path).expanduser()
    if action == "read": return p.read_text()[:1000] if p.exists() else "❌ Not found"
    return "✅ OK"
__skills__ = [
    {"name": "smart_file_op", "func": smart_file_op, "desc": "📂 Умная работа с файлами", "params": {"path": {}, "action": {"default": "read"}}, "category": "filesystem", "subcategory": "files", "domain": "local"}
]
