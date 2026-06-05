# Daycare/School Announcements — Agent + Queue Architecture

## Context

Messages are **operational school communications** sent from the school's own WhatsApp account to parents/guardians:
- payment reminders
- event announcements
- media (text, images, videos, documents)

This is **not cold outreach** — recipients have an existing relationship with the sender.

Primary goal: reliable delivery at moderate scale (20–50 recipients per campaign, potentially hundreds later) while protecting sender account health.

---

## Core Principle: Hybrid Model

| Layer | Approach | Responsibility |
|-------|----------|----------------|
| **Sending pipeline** | Deterministic (queue + worker) | Execute sends, enforce pacing, retries, cooldowns |
| **Control plane** | AI agent (advisory only) | Analyze outcomes, recommend policy adjustments |
| **Safety rails** | Hard-coded guards | Never bypassed by agent |

AI optimizes operations within safe bounds — it does not directly control send rate.

---

## Architecture Overview

```
[Frontend (Daycare Portal)]
    │
    ▼
[Campaign API]  ←──  POST /campaigns
    │
    ├──→ [Postgres: campaigns, campaign_messages, audience, sender_health]
    │
    ├──→ [Queue: SQS / BullMQ] — one job per recipient
    │
    ▼
[Worker — deterministic sender]
    ├── validates recipient (Evolution /chat/whatsappNumbers)
    ├── applies pacing policy (batch size, delay, cooldown)
    ├── sends via Evolution API (/message/sendText, /sendMedia, etc.)
    ├── stores result (provider msg ID, status, error)
    └── triggers auto-pause if risk thresholds exceeded
    │
    ▼
[Webhook / Poll] → status updates → campaign dashboard
    │
    ▼
[AI Policy Agent — periodic (every N sends or per campaign)]
    ├── reads campaign + sender health stats
    ├── recommends next-policy adjustments
    └── output validated against hard bounds before applying
```

---

## 1) Campaign API

### Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/campaigns` | Create campaign (message, audience, schedule) |
| `GET` | `/campaigns` | List campaigns |
| `GET` | `/campaigns/:id` | Campaign summary + totals |
| `GET` | `/campaigns/:id/messages` | Per-recipient status |
| `POST` | `/campaigns/:id/pause` | Pause campaign |
| `POST` | `/campaigns/:id/resume` | Resume campaign |
| `POST` | `/campaigns/:id/cancel` | Cancel pending jobs |
| `GET` | `/campaigns/:id/policy` | Current + historical policy snapshots |

### Create campaign request body

```
{
  "instanceName": "kidzee-school",
  "message": {
    "text": "Dear parent, this is a reminder...",
    "mediaUrl": "https://...",
    "mediaType": "image"
  },
  "audience": ["919970708106", "919970709106", ...],
  "schedule": "2026-06-07T09:00:00Z",      // optional
  "policyOverrides": {                       // optional
    "minDelayMs": 5000,
    "maxDelayMs": 12000,
    "batchSize": 15,
    "batchCooldownMs": 120000
  }
}
```

---

## 2) Database Schema

### `campaigns`
| Column | Type | Notes |
|--------|------|-------|
| id | UUID | PK |
| instance_name | string | Evolution instance |
| message_payload | JSON | text, mediaUrl, mediaType |
| status | enum | draft → queued → running → done → paused → cancelled |
| total_contacts | int | |
| sent_count | int | |
| failed_count | int | |
| delayed_count | int | |
| policy_snapshot_id | UUID | policy in effect |
| created_at | timestamp | |
| scheduled_at | timestamp? | nullable |
| started_at | timestamp? | |
| completed_at | timestamp? | |

### `campaign_messages`
| Column | Type | Notes |
|--------|------|-------|
| id | UUID | PK |
| campaign_id | UUID | FK → campaigns |
| recipient_number | string | E.164 |
| status | enum | queued → sending → sent → delivered → read → failed |
| attempt | int | 1-based |
| provider_msg_id | string? | Evolution `key.id` |
| failure_reason | string? | classified reason |
| error_detail | string? | raw error text |
| enqueued_at | timestamp | |
| sent_at | timestamp? | |
| delivered_at | timestamp? | from webhook |
| read_at | timestamp? | from webhook |

### `sender_health`
| Column | Type | Notes |
|--------|------|-------|
| id | UUID | PK |
| instance_name | string | per sender number |
| date | date | daily rollup |
| total_sent | int | |
| total_failed | int | |
| total_blocked | int | |
| rate_limited | int | |
| avg_delay_ms | float | |
| failure_rate | float | percentage |
| health_score | float | 0–1 computed |

### `policy_snapshots`
| Column | Type | Notes |
|--------|------|-------|
| id | UUID | PK |
| instance_name | string | |
| generated_by | enum | "system" | "agent" |
| min_delay_ms | int | lower bound |
| max_delay_ms | int | upper bound |
| batch_size | int | |
| batch_cooldown_ms | int | |
| daily_cap | int | |
| hourly_cap | int | |
| max_concurrency | int | |
| auto_pause_on_failure_rate | float | threshold |
| dry_run | boolean | applied or preview |
| applied_at | timestamp? | |

---

## 3) Queue Layer

### Queue setup (BullMQ / Redis)
- One job per recipient message
- Job priority: by campaign scheduled_at
- Job delay: calculated by worker at dispatch time
- Dead-letter queue: after max retries

### Job payload
```
{
  "campaignId": "uuid",
  "campaignMessageId": "uuid",
  "recipientNumber": "919970708106",
  "instanceName": "kidzee-school",
  "messagePayload": { "text": "...", "mediaUrl": "..." },
  "attempt": 1
}
```

### Retry policy
- Max 3 attempts
- Exponential backoff: 60s, 300s, 1800s
- No retry on: `invalid_number`, `recipient_blocked`, `number_not_on_whatsapp`
- Retry on: `timeout`, `temporary_send_limit`, `internal_error`
- Hard stop on: consecutive rate-limit signals across 5+ sends

---

## 4) Worker (deterministic sending)

### Per-recipient flow
1. Dequeue job
2. Check recipient validity (cache or `whatsappNumbers`)
3. Compute wait from current policy (random delay within bounds)
4. Send wait signal (composing presence + delay)
5. Execute Evolution API call
6. Record result + provider msg ID in `campaign_messages`
7. If failure: classify, update counts, decide retry vs dead-letter
8. If aggregate health threshold breached: auto-pause campaign + alert

### Safety rails (hard-coded, never bypassed)
- Max concurrency: 1–2
- Minimum delay: 4s (absolute floor)
- Maximum sends per batch: 20
- Batch cooldown: minimum 2 minutes
- Daily cap per instance: configurable (default 500)
- Hourly cap per instance: configurable (default 80)
- Quiet hours: no sends 22:00–07:00 recipient timezone
- Opt-out check: before every send
- Auto-pause on failure rate > 15% in last 50 sends

---

## 5) AI Policy Agent

### Role
Run **before a campaign starts** and **periodically during long campaigns** to recommend adjustments to the sending policy.

The agent does **not** sends messages. It reads telemetry and writes policy suggestions.

### Trigger cycle
- On campaign creation (initial recommendation)
- Every N sends (e.g. every 20 messages)
- On campaign pause (diagnose cause)
- On campaign completion (generate summary)

### Input (to agent)
```
{
  "campaign": { "id", "status", "sentCount", "failedCount", ... },
  "recentOutcomes": [
    { "status": "sent", "delayMs": 8000 },
    { "status": "failed", "reason": "rate_limited" },
    ...
  ],
  "health": {
    "dailySent": 120,
    "failureRate": 0.05,
    "rateLimitCount": 2,
    "blockCount": 0,
    "healthScore": 0.85
  },
  "currentPolicy": { "minDelay": 6000, "batchSize": 20, ... },
  "lastPolicyAgent": { "recommendedAt": "...", "summary": "..." }
}
```

### Output (from agent)
```
{
  "recommendedPolicy": {
    "minDelayMs": 8000,
    "maxDelayMs": 15000,
    "batchSize": 15,
    "batchCooldownMs": 180000,
    "dailyCap": 300
  },
  "reasoning": "Rate limit signals detected. Increased delay range and reduced batch size.",
  "riskLevel": "low" | "medium" | "high",
  "suggestedAction": "continue" | "slow_down" | "pause" | "halt"
}
```

### Output validation
Agent output passes through a **policy gate** that checks:
- `delay >= 4000` (absolute minimum)
- `batchSize >= 1` and `<= 30`
- `dailyCap <= 1000`
- Must have changed by at least 20% from current to avoid oscillation

If validation fails → reject agent recommendation → fall back to conservative defaults → log warning.

### Agent tech stack (recommended)
- **AI SDK ToolLoopAgent** with tools:
  - `getCampaignStats`
  - `getSenderHealth`
  - `getCurrentPolicy`
  - `getRecentOutcomes`
  - `suggestPolicy`
- Model: any capable model (Claude Sonnet, GPT-4o, Gemini)
- Memory: optional for cross-campaign awareness
- Loop control: `stepCountIs(10)` with `isLoopFinished()` fallback

---

## 6) Frontend / Portal (Daycare Principal UI)

### Campaign creation form
- Select audience (class/group, or paste numbers)
- Compose message (text + optional media)
- Schedule (now or later)
- Preview policy (suggested by agent)
- Override policy manually (advanced)

### Campaign detail view
- Progress bar (sent / total)
- Per-recipient status table (number, status, time, error)
- Action buttons: pause, resume, cancel
- Policy timeline (snapshots applied)
- Send again for failed recipients only

### Health dashboard
- Daily send volume per instance
- Failure rate chart
- Agent recommendations log
- Policy changes over time

---

## 7) Implementation Order

### Phase A (MVP — next sprint)
- Campaign API endpoints (create, list, detail)
- Queue (BullMQ + Redis) + Worker
- Deterministic sending with configurable base policy
- Per-recipient status storage
- Frontend: basic campaign creation + progress
- Validate 20–50 parent sends with current Evolution `evolution` instance

### Phase B
- AI Policy Agent integration (AI SDK ToolLoopAgent)
- Policy gate + validation
- Failure classification and retry logic
- Media support (image, video, document)

### Phase C
- Health dashboard + charts
- Quiet hours, opt-out, audience groups
- Scheduled campaigns
- Multi-instance support (multiple schools)

---

## 8) Anti-Ban / Account Health Strategy

| Risk | Mitigation |
|------|------------|
| High velocity | Hard-coded cap, delay floor, batch pause |
| Rate-limited | Auto-pause, agent adjusts policy, operator notified |
| Blocked recipient | Classify → skip on retry, no repeat |
| Content flags | Agent advisory only (school owns content) |
| Unknown failures | Log, classify via agent, escalate if pattern |

---

## 9) Example Tools for AI SDK Agent

```typescript
const tools = {
  getCampaignStats: tool({
    description: "Get current campaign status and send statistics",
    inputSchema: z.object({ campaignId: z.string() }),
    execute: async ({ campaignId }) => { /* query DB */ },
  }),
  getSenderHealth: tool({
    description: "Get sender health score and recent failure metrics",
    inputSchema: z.object({ instanceName: z.string() }),
    execute: async ({ instanceName }) => { /* query sender_health */ },
  }),
  getCurrentPolicy: tool({
    description: "Get the currently active sending policy",
    inputSchema: z.object({ instanceName: z.string() }),
    execute: async ({ instanceName }) => { /* query policy_snapshots */ },
  }),
  suggestPolicy: tool({
    description: "Recommend adjusted sending policy based on outcomes",
    inputSchema: z.object({
      reason: z.string(),
      policy: z.object({
        minDelayMs: z.number(), maxDelayMs: z.number(),
        batchSize: z.number(), batchCooldownMs: z.number(),
        dailyCap: z.number(), hourlyCap: z.number(),
      }),
    }),
    execute: async ({ policy }) => {
      // Validate against hard bounds
      // If valid, store as pending policy snapshot
      // Return status
    },
  }),
};
```

---

## 10) Notes for Demo (current state)

- Instance name: `evolution`
- API key: `429683C4C977415CAAFCCE10F7D57E11`
- Base URL: `http://localhost:8080`
- Evolution instance is `open` and confirmed working
- Demo contacts: `+919970708106`, `+919970709106`, `+917038667755`, `+918459058981`
- Bulk sender UI exists at `daycare-bulk-sender/index.html`
- All 4 demo contacts received test sends (PENDING status from API)

---

## 11) Open Questions / Decisions Log

- [ ] Should audience groups be static (upload CSV) or dynamic (query from DB)?
- [ ] Should we reuse the existing Evolution Prisma DB or add a separate campaigns DB?
- [ ] Do we run the worker in-process (same Node) or as a separate service?
- [ ] Who configures daily/hourly caps — principal in UI, or sysadmin env var?
- [ ] Opt-out: store per-recipient in DB, or rely on WhatsApp blocking?
- [ ] Media: resize/optimize before send, or pass raw URL?
