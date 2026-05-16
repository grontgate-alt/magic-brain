from sentence_transformers import SentenceTransformer
class LocalEmbedder:
    def __init__(self, model: str = "BAAI/bge-m3"):
        self.model = SentenceTransformer(model, device="cpu")  # GPU при наличии
    def embed(self, texts: list[str]) -> list[list[float]]:
        return self.model.encode(texts, normalize_embeddings=True).tolist()
    def dim(self) -> int: return 1024  # bge-m3
