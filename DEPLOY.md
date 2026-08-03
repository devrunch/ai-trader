# Deploying to EC2

One `t4g.small`, `ap-south-1` (same region as SQS and Bedrock — cross-region
calls are slower and not free). No domain: the EC2-assigned public DNS name
is the origin, TLS included via Caddy's automatic HTTPS.

## One-time setup

1. **Launch the instance** — Amazon Linux 2023 (ARM), `t4g.small`, default
   VPC. Security group: `80` and `443` open to `0.0.0.0/0`, `22` open to your
   IP only.
2. **Allocate an Elastic IP and associate it.** Without this the public
   hostname changes on every stop/start, which breaks the TLS cert and every
   bookmark. Free while attached to a running instance.
3. **Install Docker + Compose** on the instance (Amazon Linux: `dnf install
   docker`, then the Compose plugin — see AWS's own docs, it changes often
   enough that pinning steps here would go stale).
4. **Clone the three repos** onto the instance, laid out exactly as this
   machine has them:
   ```
   ~/ai-trader/
     ai-trader-frontend/
     ai-trader-api/
     ai-trader-signals/
     docker/
     docker-compose.yml
     docker-compose.prod.yml
     Caddyfile
     deploy.sh
   ```
5. **Write the three `.env` files** (`ai-trader-api/.env`,
   `ai-trader-signals/.env`, and whatever the frontend needs beyond the build
   arg) directly on the instance. They are gitignored on purpose — copy them
   over `scp`, do not commit them.
6. **Allow this instance's IP in MongoDB Atlas** — Network Access → Add IP
   Address. The app will fail to boot without this; nothing here can do it
   for you, it needs the Atlas console or API key.
7. `chmod +x deploy.sh`

## Every deploy after that

```bash
./deploy.sh
```

Pulls latest, resolves the instance's own public hostname from EC2 metadata,
rebuilds the frontend with it baked in (`NEXT_PUBLIC_API_URL` is inlined at
`next build`, not read at container start), and brings the stack up under
Caddy.

## Why no CORS config

`Caddyfile` puts the frontend and `/api/*` under one hostname. A browser
request from the page to `/api/...` is then same-origin — no CORS preflight,
no `FRONTEND_URL` mismatch to debug. `FRONTEND_URL` is still set correctly in
`docker-compose.prod.yml` as defence in depth, but the browser will never
actually exercise that path in normal use.

## What this does not cover

- **AWS credentials for the containers.** Simplest path: copy the same
  `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` this dev machine uses into
  `ai-trader-signals/.env`. Better, once this is worth the extra half hour:
  drop the static keys and attach an IAM instance role with just the SQS and
  Bedrock permissions the app actually calls — the SDK picks that up
  automatically with no code or env change, and there is no long-lived key
  sitting on disk to leak.
- **Log rotation.** `docker compose logs` will grow unbounded on a `t4g.small`
  with a 20GB disk. Fine for weeks at 10-user volume; add a `logging:` driver
  with `max-size` before it isn't.
- **Backups.** MongoDB is Atlas, which backs itself up. Nothing else here
  holds state worth backing up — the containers are stateless and rebuild
  from git plus the `.env` files.
