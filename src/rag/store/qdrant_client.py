from qdrant_client import QdrantClient
from qdrant_client.http import models as qd
from qdrant_client.http.models import Filter, FieldCondition, MatchValue

class RAGStore:
    def __init__(self, host: str = "localhost", port: int = 6333, collection: str = "magic_brain", dim: int = 1024):
        self.client = QdrantClient(host=host, port=port)
        self.collection = collection
        self.dim = dim
        if not self.client.collection_exists(collection):
            self.client.create_collection(
                collection_name=collection,
                vectors_config=qd.VectorParams(size=dim, distance=qd.Distance.COSINE)
            )
    
    def upsert(self, vectors: list[list[float]], payloads: list[dict], ids: list[str] = None):
        points = [
            qd.PointStruct(id=ids[i] if ids else i, vector=vectors[i], payload=payloads[i])
            for i in range(len(vectors))
        ]
        self.client.upsert(collection_name=self.collection, points=points)
    
    def search(self, query_vec: list[float], limit: int = 5, privacy_filter: str = None):
        # Современный API: query() вместо search()
        query_filter = None
        if privacy_filter:
            query_filter = Filter(must=[FieldCondition(key="privacy", match=MatchValue(value=privacy_filter))])
        
        results = self.client.query_points(
            collection_name=self.collection,
            query=query_vec,
            limit=limit,
            query_filter=query_filter
        )
        # results.points -> list of ScoredPoint
        return [
            {"text": p.payload.get("text","") if p.payload else "", "meta": p.payload or {}, "score": p.score}
            for p in (results.points if hasattr(results, "points") else [])
        ]
    
    def add_text(self, text: str, meta: dict, id: str = None):
        """Удобный метод для добавления текста в RAG"""
        from rag.embed.local_embedder import LocalEmbedder
        embedder = LocalEmbedder()
        vec = embedder.embed([text])[0]
        self.upsert([vec], [meta | {"text": text}], [id] if id else None)
