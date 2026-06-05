# Daycare Bulk Sender

Simple tooling around Evolution API for fast demos:
- static web sender (`index.html`)
- CLI bulk sender (`send-announcement.sh`)
- one-command backend bootstrap (`start-evolution.sh`)

## Files

- `index.html`
- `styles.css`
- `app.js`
- `send-announcement.sh`
- `start-evolution.sh`
- `stop-evolution.sh`

## One-command Evolution startup

Run from repo root:

```bash
bash bulk-sender/start-evolution.sh
```

What it does:
- ensures `.env` exists (copies from `.env.example` if missing)
- starts Postgres + Redis (only if ports are down)
- applies Prisma generate + migrate deploy
- starts Evolution API and waits for `http://localhost:8080/`

Useful options:

```bash
bash bulk-sender/start-evolution.sh --foreground
bash bulk-sender/start-evolution.sh --no-docker
bash bulk-sender/start-evolution.sh --skip-install
```

Stop API (and optionally helper containers):

```bash
bash bulk-sender/stop-evolution.sh
bash bulk-sender/stop-evolution.sh --with-services
```

## Web UI sender

1. Open `bulk-sender/index.html` in a browser.
2. Fill/verify:
   - Evolution API Base URL (`http://localhost:8080`)
   - Instance Name (`evolution`)
   - API Key
   - Contacts and message
3. Click **Validate Contacts**.
4. Click **Send to Valid Contacts**.

## CLI bulk sender

Default contacts are prefilled in `send-announcement.sh`.

```bash
bash bulk-sender/send-announcement.sh
```

Override message inline:

```bash
MESSAGE="Your custom announcement" bash bulk-sender/send-announcement.sh
```

## Notes

- Send flow uses paced delays to reduce account risk.
- API `PENDING` means accepted by API/WhatsApp transport, not guaranteed final delivery.
- If instance is not `open`, fetch QR via `/instance/connect/:instanceName` and scan from WhatsApp Linked Devices.
