# glasse memory-service — per-user agent memory via Redis Agent Memory (Iris)

Gives **Bob** (the glasse conductor) **cross-session, per-user memory**: tell it once
("always describe things in detail", "I take the bus to work") and it remembers and
applies that next time. Backed by **managed Redis Agent Memory (Iris)** — agent
memory + semantic retrieval, the "**beyond caching**" story.

Architecture is unchanged from before — this service is now a **thin proxy** to Iris
so the iOS app never holds the Iris key:

```
 glasse (iOS, MemoryClient.swift)
     │  command + owner_id (your auth)
     ▼
 this memory-service  ──REST──►  Redis Agent Memory (Iris, Redis Cloud)
     │   /memory/search  (before Claude)        stores per-user memories as text
     │   call Claude (your existing conductor)  + embeddings; semantic recall;
     │   /memory/learn or /memory/remember      auto-promotes durable prefs
     ▼
 Claude API
```

## What's here
| file | purpose |
|---|---|
| `memory.py` | thin proxy: forwards search / remember / learn to the Iris REST API |
| `app.py` | FastAPI: `/memory/search`, `/memory/learn`, `/memory/remember`, `/healthz` |
| `Dockerfile` · `docker-compose.yml` · `.env.example` | container + local run + the Iris creds to set |
| `../glasse/MemoryClient.swift` | the Swift client (unchanged) |

## 1. Set up Iris (Redis Cloud)
> Iris Agent Memory is in **preview**, and Redis Cloud is a third-party platform —
> get the account/credentials through your **approved company channels**, keep the
> key in a secret manager, not in code.

1. Create a database on Redis Cloud.
2. Create an **Agent Memory** service for it.
3. Copy the **host**, **store id**, and **API key** into `.env` (see `.env.example`).

## 2. Run the proxy
```bash
cd memory-service
cp .env.example .env   # fill in IRIS_HOST / IRIS_STORE_ID / IRIS_API_KEY
docker compose up --build      # → http://localhost:8080
```
```bash
# teach it something (immediate, explicit)
curl -s localhost:8080/memory/remember -H 'content-type: application/json' \
  -d '{"owner_id":"alice","text":"prefers detailed scene descriptions"}'
# recall what's relevant to a request
curl -s localhost:8080/memory/search -H 'content-type: application/json' \
  -d '{"owner_id":"alice","query":"describe what is in front of me"}'
```
You can watch the same memories in the **Agent Memory view in the Redis Cloud console**.

## 3. Deploy (approved cloud)
The proxy is just a container — run it on **AWS ECS/Fargate · GCP Cloud Run · Azure
Container Apps**, with `IRIS_*` from the cloud's secret manager, behind your auth so
`owner_id` is a trusted user id (clients can't read each other's memory). Iris itself
is managed (Redis Cloud), so there's no Redis instance for you to operate.

## 4. Wire it into glasse (unchanged)
Drop in `glasse/MemoryClient.swift`, set `MemoryClient.baseURL` to the deployed URL,
and add two calls in `startConductor` (`ContentView.swift`):
- **before Claude:** `let recalled = await memory.recall(query: transcript)` → fold into `conductorSystemPrompt()` as "What I've learned about this user".
- **after the reply:** `memory.learn(userText: transcript, assistantText: reply)`.

For the explicit path, your conductor's existing `remember` tool can call
`memory.remember(text)` (e.g. "prefers detailed descriptions").

## Memory paths
- `/memory/remember` → stores a memory in Iris long-term **immediately** (use for the
  conductor's `remember` tool / "remember that I…").
- `/memory/learn` → records the turn as Iris **session events**; Iris auto-promotes
  durable preferences to long-term in the background.
- `/memory/search` → semantic recall of the user's long-term memories (owner + namespace filtered).

## Notes
- Iris does embeddings, vector search, and extraction server-side — so this proxy has
  no embedding model or vector-index code (that's why deps are tiny).
- Two different "agent memory" products exist — this targets the **hosted Iris**
  (`ownerId`/`storeId`, Bearer key). The open-source `agent-memory-server`
  (`user_id`, self-host) has a different API; don't mix them.
- Rotate the keys pasted in chat earlier; everything secret stays in this backend.
