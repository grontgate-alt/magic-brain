import os, yaml, json, uuid, sys
from pathlib import Path
from qdrant_client import QdrantClient
from qdrant_client.http import models as qd

BASE = Path(__file__).parent.parent.parent
REGISTRY_FILE = BASE / "config" / "skills-registry.json"
COL_NAME = "magic_brain_skills"

class SkillRouter:
    def __init__(self):
        self.qdrant = QdrantClient(host=os.getenv("QDRANT_HOST","localhost"), port=int(os.getenv("QDRANT_PORT","6333")))
        self.skills = {}
        self.embedder = None
        self._load_registry()
        
    def _get_embedder(self):
        if not self.embedder:
            from rag.embed.local_embedder import LocalEmbedder
            self.embedder = LocalEmbedder()
        return self.embedder

    def _load_registry(self):
        yaml_path = BASE / "config" / "skills-tree.yaml"
        if not yaml_path.exists(): return
        raw = yaml.safe_load(yaml_path.read_text())
        # Формируем плоский список скилов из дерева
        for cat in raw.get("categories", []):
            for s in cat.get("skills", []):
                sid = s.get("id")
                self.skills[sid] = {
                    "id": sid, "name": s.get("name", sid), "desc": s.get("desc",""),
                    "keywords": s.get("keywords","").split(","), "privacy": s.get("privacy","MEDIUM"),
                    "enabled": True, "path": f"agents/skills/{cat.get('id','unknown')}/{sid}.py"
                }
        print(f"📦 Загружено {len(self.skills)} скилов из YAML")

    def sync_to_qdrant(self):
        emb = self._get_embedder()
        if not self.qdrant.collection_exists(COL_NAME):
            self.qdrant.create_collection(COL_NAME, vectors_config=qd.VectorParams(size=1024, distance=qd.Distance.COSINE))
        points, ids = [], []
        for sid, m in self.skills.items():
            text = f"{m['desc']}. Ключевые слова: {', '.join(m['keywords'])}"
            vec = emb.embed([text])[0]
            ids.append(str(uuid.uuid4()))
            points.append(qd.PointStruct(id=ids[-1], vector=vec, payload={"skill_id": sid, "name": m["name"], "privacy": m["privacy"]}))
        self.qdrant.upsert(COL_NAME, points)
        print(f"✅ Векторизовано {len(points)} скилов в Qdrant")

    def search(self, query: str, limit: int = 5, privacy_mode: str = "CLOUD"):
        emb = self._get_embedder()
        vec = emb.embed([query])[0]
        hits = self.qdrant.query_points(COL_NAME, query=vec, limit=limit*2)
        res = []
        for p in hits.points:
            if not p.payload["skill_id"] in self.skills: continue
            sk = self.skills[p.payload["skill_id"]]
            if privacy_mode == "LOCAL" and sk["privacy"] == "LOW": continue
            if not sk["enabled"]: continue
            res.append({"skill_id": p.payload["skill_id"], "name": p.payload["name"], "score": p.score, "privacy": p.payload["privacy"]})
        return sorted(res, key=lambda x: x["score"], reverse=True)[:limit]

    def toggle(self, skill_id: str, state: bool):
        if skill_id in self.skills:
            self.skills[skill_id]["enabled"] = state
            print(f"🔘 {skill_id} → {'ON' if state else 'OFF'}")
            
    def reload(self):
        self.skills.clear()
        self._load_registry()
        self.sync_to_qdrant()
router = SkillRouter()
