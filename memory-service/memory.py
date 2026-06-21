"""
Per-user long-term agent memory for glasse — backed by the MANAGED Redis Agent
Memory (Iris) service on Redis Cloud (preview).

This backend is a THIN PROXY: it holds the Iris credentials and forwards the app's
memory calls to Iris over REST, so the iOS app never sees the key. The /memory/*
API and the iOS MemoryClient are unchanged — only the storage backend swapped from
local RedisVL to managed Iris. Iris does the embeddings, vector search, and (for
the session path) automatic promotion of durable preferences to long-term memory,
so this layer is small.

Endpoints used (Iris REST, scoped to a storeId, auth = Bearer API key):
  POST /v1/stores/{storeId}/long-term-memory          (store)
  POST /v1/stores/{storeId}/long-term-memory/search   (semantic recall, owner/namespace filtered)
  POST /v1/stores/{storeId}/session-memory/events     (record a turn → Iris auto-promotes)
"""

from __future__ import annotations

import os
import uuid

import httpx

# From the Redis Cloud console (create a DB → create an Agent Memory service).
# Get these through approved company channels; keep them in a secret manager.
IRIS_HOST = os.environ.get("IRIS_HOST", "").rstrip("/")   # e.g. https://<id>.agent-memory.redis.cloud
IRIS_STORE_ID = os.environ.get("IRIS_STORE_ID", "")
IRIS_API_KEY = os.environ.get("IRIS_API_KEY", "")
NAMESPACE_DEFAULT = os.environ.get("MEMORY_NAMESPACE", "glasse-prod")


def _base() -> str:
    if not (IRIS_HOST and IRIS_STORE_ID and IRIS_API_KEY):
        raise RuntimeError("Set IRIS_HOST, IRIS_STORE_ID, IRIS_API_KEY (Redis Cloud → Agent Memory).")
    return f"{IRIS_HOST}/v1/stores/{IRIS_STORE_ID}"


def _headers() -> dict:
    return {"Authorization": f"Bearer {IRIS_API_KEY}", "content-type": "application/json"}


def ensure_index() -> dict:
    """Iris manages the store — nothing to create. Validates config so boot/healthz fail loudly."""
    _ = _base()
    return {"backend": "redis-iris", "store": IRIS_STORE_ID}


def search_memories(owner_id: str, query: str, *, namespace: str = NAMESPACE_DEFAULT,
                    limit: int = 5) -> list[dict]:
    """Semantic recall of THIS user's long-term memories relevant to `query`."""
    body = {
        "text": query,
        "filter": {"ownerId": {"eq": owner_id}, "namespace": {"eq": namespace}},
        "filterOp": "all",
    }
    with httpx.Client(timeout=10) as c:
        r = c.post(f"{_base()}/long-term-memory/search", headers=_headers(), json=body)
    if r.status_code != 200:
        return []
    payload = r.json()
    # Iris returns matches under "items" (confirmed live); fall back to other keys.
    items = payload.get("items") or payload.get("memories") or payload.get("results") or []
    out = []
    for m in items[:limit]:
        if text := m.get("text"):
            out.append({"text": text, "type": m.get("memoryType", "semantic")})
    return out


def remember(owner_id: str, text: str, *, mtype: str = "semantic",
             namespace: str = NAMESPACE_DEFAULT) -> dict:
    """Store one durable memory immediately (the explicit 'remember that I…' path)."""
    text = (text or "").strip()
    if not text:
        return {"stored": False, "reason": "empty"}
    body = {"memories": [{
        "id": uuid.uuid4().hex,
        "text": text,
        "memoryType": mtype,        # "semantic" = preferences/facts; "episodic" = events
        "ownerId": owner_id,
        "namespace": namespace,
    }]}
    with httpx.Client(timeout=10) as c:
        r = c.post(f"{_base()}/long-term-memory", headers=_headers(), json=body)
    return {"stored": r.status_code in (200, 201), "text": text, "status": r.status_code}


def learn_from_turn(owner_id: str, user_text: str, assistant_text: str, *,
                    namespace: str = NAMESPACE_DEFAULT) -> dict:
    """Record a turn as session events; Iris asynchronously promotes durable
    preferences to long-term in the background. (Use remember() for an immediate,
    explicit store.) A rolling per-user session keeps related turns together."""
    events = []
    if (user_text or "").strip():
        events.append({"role": "USER", "actorId": owner_id, "content": [{"text": user_text}]})
    if (assistant_text or "").strip():
        events.append({"role": "ASSISTANT", "actorId": "assistant", "content": [{"text": assistant_text}]})
    sent = 0
    with httpx.Client(timeout=10) as c:
        for ev in events:
            ev["sessionId"] = owner_id
            ev["namespace"] = namespace
            r = c.post(f"{_base()}/session-memory/events", headers=_headers(), json=ev)
            if r.status_code in (200, 201):
                sent += 1
    return {"recorded": sent}
