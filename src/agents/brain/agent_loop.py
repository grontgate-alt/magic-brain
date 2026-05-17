import logging
from agents.brain.session import Session
from agents.brain.planner import plan, replan

async def run(query: str, uid: int, registry) -> str:
    session = await Session.create(uid, query)
    await session.save()

    steps = await plan(query, registry)
    if not steps: return "❌ Не удалось составить план."
    session.plan = steps
    await session.save()
    logging.info(f"📋 Plan: {[s['tool'] for s in steps]}")

    for i, step in enumerate(steps):
        if i > session.max_steps: break
        session.step_idx = i
        tool_name, args = step.get("tool"), step.get("args", {})

        if tool_name not in registry.skills:
            session.add_result(i, f"❌ Инструмент {tool_name} отсутствует в реестре", False)
            await session.save()
            continue

        try:
            logging.info(f"⚙️ Step {i}: {tool_name}({args})")
            res = await registry.skills[tool_name]["func"](query, {}, uid, **args)
            session.add_result(i, res, True)
            await session.save()
        except Exception as e:
            err = f"❌ Ошибка {tool_name}: {e}"
            logging.error(err)
            session.add_result(i, err, False)
            await session.save()
            
            new_steps = await replan(err, session.context, registry)
            if new_steps:
                steps[i+1:] = new_steps
                logging.info(f"🔄 Plan adjusted")
                await session.save()
            else: break

    return session.context[-1]["output"] if session.context else "✅ Выполнено"
