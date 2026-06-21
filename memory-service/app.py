"""
glasse memory-service — HTTP API the glasse app calls (through your backend) to
give Bob per-user, cross-session memory.

Endpoints
  GET  /healthz                 liveness + index info
  POST /memory/search           retrieve relevant memories for a user (call BEFORE Claude)
  POST /memory/learn            extract durable prefs from a turn + store (call AFTER Claude)
  POST /memory/remember         store one explicit memory ("remember that I…")

The mobile app must NOT hold Redis/Anthropic creds — it talks to THIS service, which
holds them via env vars. Front it with your auth so `owner_id` is a trusted user id,
and run it on an approved cloud (AWS/GCP/Azure). See README.md.
"""

from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import FastAPI
from pydantic import BaseModel, Field

import memory


@asynccontextmanager
async def lifespan(_: FastAPI):
    memory.ensure_index()   # idempotent: create the vector index on boot
    yield


app = FastAPI(title="glasse memory-service", version="1.0.0", lifespan=lifespan)


class SearchIn(BaseModel):
    owner_id: str = Field(..., description="stable per-user id from your auth")
    query: str
    namespace: str = memory.NAMESPACE_DEFAULT
    limit: int = 5


class LearnIn(BaseModel):
    owner_id: str
    user_text: str
    assistant_text: str = ""
    namespace: str = memory.NAMESPACE_DEFAULT


class RememberIn(BaseModel):
    owner_id: str
    text: str
    type: str = "preference"
    namespace: str = memory.NAMESPACE_DEFAULT


@app.get("/healthz")
def healthz():
    return {"ok": True, **memory.ensure_index()}


@app.post("/memory/search")
def search(body: SearchIn):
    mems = memory.search_memories(body.owner_id, body.query,
                                  namespace=body.namespace, limit=body.limit)
    return {"memories": mems}


@app.post("/memory/learn")
def learn(body: LearnIn):
    return memory.learn_from_turn(body.owner_id, body.user_text, body.assistant_text,
                                  namespace=body.namespace)


@app.post("/memory/remember")
def remember(body: RememberIn):
    return memory.remember(body.owner_id, body.text, mtype=body.type, namespace=body.namespace)
