"""📐 Pydantic-схема скилов. Валидация на старте, 0 runtime-мусора."""
from typing import Any, Dict, List, Optional, Literal
from pydantic import BaseModel, Field, field_validator

class SkillStep(BaseModel):
    id: str
    tool: str
    args: Dict[str, Any] = Field(default_factory=dict)
    condition: Optional[str] = None  # Jinja-шаблон или простое выражение "status == 'success'"
    on_error: Literal["skip", "abort", "retry"] = "abort"
    max_retries: int = 1

class SkillDefinition(BaseModel):
    id: str
    name: str
    description: str
    category: str
    version: str = "1.0.0"
    steps: List[SkillStep]
    memory_keys: List[str] = Field(default_factory=list)  # Ключи для сохранения в сессии
    timeout_sec: int = 120

    @field_validator('steps')
    @classmethod
    def steps_must_have_unique_ids(cls, v: List[SkillStep]) -> List[SkillStep]:
        ids = [s.id for s in v]
        if len(ids) != len(set(ids)):
            raise ValueError("Step IDs must be unique")
        return v

class SkillsRegistry:
    def __init__(self, skills_dir: str = "~/magic-brain-deploy/src/agents/skills"):
        self.skills_dir = Path(skills_dir).expanduser()
        self.skills_dir.mkdir(parents=True, exist_ok=True)
        self._registry: Dict[str, SkillDefinition] = {}

    def load(self):
        import yaml, logging
        self._registry.clear()
        for f in self.skills_dir.glob("*.yaml"):
            try:
                with open(f) as fh:
                    data = yaml.safe_load(fh)
                skill = SkillDefinition(**data)
                self._registry[skill.id] = skill
                logging.info(f"✅ Skill loaded: {skill.id} ({skill.name})")
            except Exception as e:
                logging.warning(f"⚠️ Skill parse failed {f.name}: {e}")
        logging.info(f"📊 Skills Registry: {len(self._registry)} loaded")

    def get(self, skill_id: str) -> Optional[SkillDefinition]:
        return self._registry.get(skill_id)

    def list_skills(self) -> List[Dict[str, str]]:
        return [{"id": s.id, "name": s.name, "desc": s.description, "category": s.category}
                for s in self._registry.values()]

from pathlib import Path
