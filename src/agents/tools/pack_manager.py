import contextlib
from pathlib import Path

import git


class PackManager:
    def __init__(self):
        self.dir = Path(__file__).parent / "packs"
        self.dir.mkdir(exist_ok=True)
        self.sources = {
            "langchain": {
                "url": "https://github.com/langchain-ai/langchain.git",
                "path": "libs/community/langchain_community/tools",
            },
            "openwebui": {"url": "https://github.com/open-webui/functions.git", "path": "examples"},
        }

    def sync(self):
        for pid, cfg in self.sources.items():
            local = self.dir / pid
            try:
                if local.exists():
                    git.Repo(local).remotes.origin.pull()
                    print(f"🔄 {pid} updated")
                else:
                    git.Repo.clone_from(cfg["url"], local, depth=1)
                    print(f"✅ {pid} cloned")
            except Exception as e:
                print(f"⚠️ {pid}: {e}")

    def adapt(self):
        skills = {}
        for pid, cfg in self.sources.items():
            p = self.dir / pid / cfg["path"]
            if not p.exists():
                continue
            for f in p.rglob("*.py"):
                if "__" in f.name or "test" in str(f):
                    continue
                with contextlib.suppress(BaseException):
                    skills[f"{pid}_{f.stem}"] = {
                        "desc": f"Pack:{pid}",
                        "privacy": "CLOUD" if "web" in str(f) or "search" in str(f) else "LOCAL",
                        "code": f'''
import importlib.util, sys
spec = importlib.util.spec_from_file_location("m", "{f}")
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
def __skill__(): return {{"name":"{pid}_{f.stem}","desc":"Auto:{pid}","params":{{}},"privacy":"{"CLOUD" if "web" in str(f) or "search" in str(f) else "LOCAL"}"}}
async def {pid}_{f.stem}(q, ctx, uid, **kw):
    try:
        fn = getattr(mod, "run", getattr(mod, "execute", None))
        return str(fn(q) if fn else mod)[:2000]
    except Exception as e: return f"⚠️ {{e}}"
''',
                    }
        return skills


pack_mgr = PackManager()
