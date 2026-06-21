# Redis-backed memory — setup

Gives Bob **persistent, semantic, cross-session memory** (remember/recall) backed by
Redis vector search. The iOS app never speaks Redis (no creds in the binary): it calls
a backend over HTTPS, which holds the Redis + embedder creds.

```
glasse (iOS, HTTPS + bearer token)  ->  memory-service (backend)  ->  managed Redis (vector search)
```

## ✅ Already done (in this repo)
- **iOS client:** `glasse/RemoteMemoryStore.swift` — drop-in for `MemoryStore` (same
  `remember`/`recall`/`promptBlock`/`notes` API). On-device `MemoryStore` stays as a
  write-through cache so recall/prompt are synchronous and **offline behavior is
  identical**. Wired in `ContentView`: `memory = RemoteMemoryStore()`, `prime(query:)`
  before each conductor turn, `learn(...)` after the reply.
- **Backend:** `memory-service/` (FastAPI: `app.py`, `memory.py`, `Dockerfile`,
  `docker-compose.yml`) — serves `/memory/search`, `/memory/remember`, `/memory/learn`,
  which `MemoryClient.swift` already calls.
- **Safe until configured:** with `MemoryClient.baseURL = ""` every remote call no-ops,
  so the app keeps using on-device memory. Setting `baseURL` turns Redis on.

## 🔧 To turn it on (your side — approved cloud only)
1. **Provision managed Redis WITH vector search** (private in the VPC, `rediss://` TLS):
   - **AWS (recommended):** **MemoryDB** for Valkey/Redis on R6g/R7g/T4g with a
     **search-enabled parameter group set AT CREATE time** (can't be toggled later);
     single-shard is fine. (ElastiCache Valkey 8.2+ is the cache-first alternative.)
   - **GCP:** Memorystore for Redis 7.2+ (HASH; VECTOR/NUMERIC/TAG fields).
   - **Azure:** Azure Managed Redis (RediSearch module, Enterprise clustering, NoEviction).
   - ❌ Not Redis Cloud / Upstash / personal-or-free-tier accounts — confirm provisioning
     through your team's approved AWS/GCP/Azure channel.
2. **Enable embeddings on the same cloud** — the index `DIM` must equal the model's output:
   - AWS **Bedrock** `amazon.titan-embed-text-v2:0` (1024, normalized).
   - GCP **Vertex AI** `gemini-embedding-001` (768; backend must L2-normalize).
   - Azure **OpenAI** `text-embedding-3-small` (1536).
3. **Deploy the `memory-service` container** on **App Runner / ECS Fargate** (AWS) /
   **Cloud Run** (GCP) / **Azure Container Apps** — *not* a VPC Lambda (it loses internet
   egress to Bedrock). Give it egress to the embedder + secret manager (VPC interface
   endpoints) and to Redis on 6379 over TLS.
4. **Secrets** in the cloud secret manager (never in the app/image): Redis `rediss://`
   URL, embedder/cloud creds, `ANTHROPIC_API_KEY` (only for `/learn`), and the shared
   **bearer token**.
5. **Point the app at it:** set `MemoryClient.baseURL` to the deployed HTTPS URL (+ the
   bearer token) via `Secrets.swift` (gitignored) — that flips memory on.

**Test locally first:** `memory-service/docker-compose.yml` runs Redis 8 + the service
so you can validate `/memory/*` end-to-end before any cloud spend.

## ⚠️ Decisions / caveats (verified)
- **Embedding DIM is baked into the index** at `FT.CREATE`. Changing model/dim means
  `FT.DROPINDEX` + recreate + re-embed every note. Pin the model id + dim in backend
  config — a dim mismatch is the #1 failure mode.
- **Schema portability:** `memory.py` currently indexes `text` as a RediSearch **TEXT**
  field, which **only AWS MemoryDB supports** (not GCP Memorystore or ElastiCache Valkey
  8.2). For GCP/ElastiCache, store `text`/`category` UNINDEXED and index only
  `owner_id`/`namespace`/`type` (TAG) + `created_at` (NUMERIC) + `embedding` (VECTOR).
  *(I can make this edit.)*
- **No auth yet:** the shipped backend takes `owner_id` in the body with no token. Add
  **bearer-token auth → server-derived `owner_id`** before exposing it publicly. *(I can
  make this edit.)*
- **Cross-DEVICE** memory needs a real user identity; today `owner_id` is a per-install
  UUID (`MemoryClient.ownerID`), so it's per-install until you add auth.
- **Rotate** the Anthropic/Deepgram keys pasted earlier and keep them only in the secret
  manager.
