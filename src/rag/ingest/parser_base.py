from abc import ABC, abstractmethod
from pathlib import Path
from typing import List, Dict, Any

class ParsedChunk:
    def __init__(self, text: str, meta: Dict[str, Any]):
        self.text = text
        self.meta = meta  # source, type, timestamp, privacy_level

class BaseParser(ABC):
    @abstractmethod
    def can_parse(self, path: Path) -> bool: ...
    @abstractmethod
    def parse(self, path: Path) -> List[ParsedChunk]: ...
    
    def safe_meta(self, path: Path, source: str) -> Dict:
        return {"source": str(path), "type": source, "privacy": "HIGH" if "personal" in str(path).lower() else "LOW"}
