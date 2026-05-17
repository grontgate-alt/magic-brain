from abc import ABC, abstractmethod
from pathlib import Path
from typing import Any


class ParsedChunk:
    def __init__(self, text: str, meta: dict[str, Any]):
        self.text = text
        self.meta = meta  # source, type, timestamp, privacy_level


class BaseParser(ABC):
    @abstractmethod
    def can_parse(self, path: Path) -> bool: ...
    @abstractmethod
    def parse(self, path: Path) -> list[ParsedChunk]: ...

    def safe_meta(self, path: Path, source: str) -> dict:
        return {
            "source": str(path),
            "type": source,
            "privacy": "HIGH" if "personal" in str(path).lower() else "LOW",
        }
