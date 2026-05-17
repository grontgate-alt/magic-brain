import json

from telegram import InlineKeyboardButton, InlineKeyboardMarkup
from telegram.error import BadRequest

# === ЗАФИКСИРОВАННЫЙ ДИЗАЙН (НЕ МЕНЯТЬ) ===
MODES = {"agent": "🛠️ Агент", "chat": "💬 Чат", "rag": "🗄️ Память", "web": "🌐 Веб"}


def get_keyboard(active_mode: str = "auto") -> InlineKeyboardMarkup:
    """Всегда 2x2 сетка, активный режим подсвечен ✅"""
    btns = []
    for mode, label in MODES.items():
        icon = "✅" if mode == active_mode else "🔘"
        data = json.dumps({"t": "mode_switch", "m": mode})
        btns.append(InlineKeyboardButton(f"{icon} {label}", callback_data=data))
    return InlineKeyboardMarkup([btns[:2], btns[2:]])


async def safe_reply(message, text: str, mode: str = "auto"):
    """Надёжная отправка с клавиатурой. Никогда не падает."""
    kb = get_keyboard(mode)
    try:
        await message.reply_text(text, reply_markup=kb)
    except BadRequest:
        try:
            await message.reply_text(str(text)[:1000], reply_markup=kb)
        except:
            await message.reply_text("✅", reply_markup=kb)
    except:
        pass
