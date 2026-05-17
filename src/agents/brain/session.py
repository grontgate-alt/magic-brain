import os, json, uuid, time, logging
from pathlib import Path

SESSIONS_DIR = Path(os.path.expanduser("~/.magic-brain/sessions"))
SESSIONS_DIR.mkdir(parents=True, exist_ok=True)

class Session:
    def __init__(self, uid: int, query: str):
        self.id = str(uuid.uuid4())[:8]
        self.uid, self.query = uid, query
        self.plan, self.step_idx, self.context = [], 0, []
        self.max_steps, self.created = 5, time.time()

    async def save(self):
        p = SESSIONS_DIR / f"{self.uid}_{self.id}.json"
        p.write_text(json.dumps({"id":self.id,"uid":self.uid,"query":self.query,"plan":self.plan,
                                 "step_idx":self.step_idx,"context":self.context,"max_steps":self.max_steps}, indent=2))

    def add_result(self, step_id, output, success=True):
        self.context.append({"step":step_id, "output":str(output)[:800], "success":success, "time":time.time()})
        if len(self.context) > 4: self.context = self.context[-3:]  # prune
        self.step_idx += 1

    @classmethod
    async def create(cls, uid, query):
        return cls(uid, query)
