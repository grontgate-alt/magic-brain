"""🧠 Мета-навыки"""
async def install_new_skill(q, ctx, uid, pack_url: str) -> str:
    return f"📥 Installing pack from {pack_url}... (stub)"
__skills__ = [
    {"name": "install_new_skill", "func": install_new_skill, "desc": "📦 Установка навыка", "params": {"pack_url": {}}, "category": "meta", "subcategory": "self_update", "domain": "local"}
]
