from .parser_base import BaseParser, ParsedChunk
from pathlib import Path
from pypdf import PdfReader
class PDFParser(BaseParser):
    def can_parse(self, path: Path) -> bool: return path.suffix.lower() == ".pdf"
    def parse(self, path: Path) -> list[ParsedChunk]:
        reader = PdfReader(path)
        chunks = []
        for i, page in enumerate(reader.pages):
            txt = page.extract_text() or ""
            if txt.strip():
                chunks.append(ParsedChunk(txt, self.safe_meta(path, "pdf") | {"page": i+1}))
        return chunks
