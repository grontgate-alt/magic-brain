"""🖥️ Системные инструменты"""

import subprocess


async def run_bash(q, ctx, uid, cmd: str) -> str:
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=20)
    return (r.stdout + r.stderr).strip()[:1000]


__skills__ = [
    {
        "name": "run_bash",
        "func": run_bash,
        "desc": "💻 Shell-команда",
        "params": {"cmd": {}},
        "category": "system",
        "subcategory": "shell",
        "domain": "local",
    }
]
