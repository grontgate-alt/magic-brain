import subprocess, os, logging

async def run_bash(query, ctx, uid, command: str, timeout: int = 30) -> str:
    try:
        res = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=timeout, cwd="/home/der")
        out = (res.stdout + res.stderr).strip()
        return out[:3000] if out else "✅ Выполнено. Нет вывода."
    except subprocess.TimeoutExpired: return "⏱️ Таймаут"
    except Exception as e: return f"❌ Ошибка: {e}"

__skills__ = [{
    "name": "run_bash",
    "desc": "🔥 DIRECT SYSTEM ACCESS. Runs ANY bash command. Use for logs, files, network, packages, processes. Pass full command in 'command'.",
    "params": {"command": {"type": "string"}, "timeout": {"type": "integer", "default": 30}},
    "func": run_bash, "privacy": "LOCAL"
}]
