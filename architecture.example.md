# Platform Architecture

> **This file is optional.** If present, workstrator injects it into every agent's system
> prompt so the Planner can understand how services relate and make better cross-repo plans.
>
> Copy this to `architecture.md` and replace with your own platform details.

## Architecture Overview

```
Clients:   Web App  ·  Mobile App  ·  Admin Dashboard
              │            │              │
         REST / WS    REST / WS     Firebase Auth
              │            │              │
         API Gateway ────┬──── Dashboard API
              │          │          │
         Worker Service  │     Database
              │          │     (collections: users, orgs, items, ...)
         External APIs   │
              │          │
         Object Storage ─┘
```

## Service → Repo Map

| Local directory | Repo | Runtime | What it does |
|---|---|---|---|
| `api/` | `your-org/api` | Node 22, Express | REST API, auth, CRUD |
| `web/` | `your-org/web` | React, Vite | Browser client |
| `mobile/` | `your-org/mobile` | Swift / Kotlin | Native mobile app |
| `worker/` | `your-org/worker` | Node 22 | Background jobs, queues |
| `shared-types/` | `your-org/shared-types` | TypeScript | Shared type definitions |
| `infra/` | `your-org/infra` | Terraform | Infrastructure as code |

## Database Collections

| Collection | Key fields | Used by |
|---|---|---|
| `users/{uid}` | email, role, orgId | API, Dashboard |
| `orgs/{orgId}` | name, plan, settings | All services |
| `items/{itemId}` | orgId, type, data | API, Worker |

## Key Integration Points

- **API ↔ Worker:** Message queue (SQS/Pub-Sub). API enqueues jobs, Worker processes them.
- **Auth:** JWT tokens issued by API, validated by all services.
- **Storage:** S3/GCS buckets for file uploads. Worker processes uploads asynchronously.
