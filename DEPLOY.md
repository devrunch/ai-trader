# Deploying to EC2

One `t4g.small` (2 GB, ARM) in `ap-south-1`, same region as Bedrock. No
domain: `<elastic-ip>.sslip.io` is the origin, TLS included via Caddy's
automatic HTTPS.

Every service is a **systemd unit**. There is no container runtime on the box
— `dockerd` and `containerd` cost ~450 MB resident on a machine with 2 GB,
which is more than the news engine and the terminal use together.

| Unit | What it runs | Notes |
|---|---|---|
| `ai-trader-signals` | FastAPI, live ticks, chat agent, six cron jobs | `MemoryMin=300M`, `OOMScoreAdjust=-500` — killed last |
| `ai-trader-newsd` | the hourly news pipeline, alone | `MemoryMax=350M`, no swap, `OOMScoreAdjust=+500` — killed first |
| `ai-trader-api` | NestJS | built on the box; `node dist/main` |
| `ai-trader-frontend` | Next.js standalone server | the bundle CI built, never built here |
| `caddy`, `redis-server` | TLS/reverse proxy, pub-sub + job store | distro packages |

## One-time setup

1. **Launch the instance** — Ubuntu 24.04 (ARM), `t4g.small`, default VPC.
   Security group: `80` and `443` open to `0.0.0.0/0`, `22` open to your IP.
2. **Allocate an Elastic IP and associate it.** Without it the public
   hostname changes on every stop/start, which breaks the TLS cert and every
   bookmark. Free while attached to a running instance.
3. **Install the runtimes and services:**
   ```bash
   sudo apt-get install -y python3-venv redis-server
   curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt-get install -y nodejs
   # Caddy: see caddyserver.com/docs/install#debian-ubuntu-raspbian
   ```
4. **Clone the three repos** onto the instance, laid out exactly as this
   machine has them:
   ```
   ~/ai-trader/
     ai-trader-frontend/     # only for its git history; the bundle comes from CI
     ai-trader-api/
     ai-trader-signals/
     systemd/
     Caddyfile
     deploy.sh
   ```
5. **Create the Python venv** the units point at:
   ```bash
   python3 -m venv ~/ai-trader/venv-signals
   ~/ai-trader/venv-signals/bin/pip install -r ~/ai-trader/ai-trader-signals/requirements.txt
   ```
6. **Write the `.env` files** (`ai-trader-api/.env`, `ai-trader-signals/.env`)
   directly on the instance. They are gitignored on purpose — copy them over
   `scp`, never commit them.
7. **Allow this instance's IP in MongoDB Atlas** — Network Access → Add IP
   Address. The app will not boot without it, and nothing here can do it for
   you.
8. `chmod +x deploy.sh`

## Every deploy after that

CI does it: each repo's workflow runs its tests, then SSHes in with a key
whose forced command is `deploy.sh` under `flock`, so deploys serialise across
repos. By hand it is the same script:

```bash
./deploy.sh
```

It resolves the instance's own public hostname from EC2 metadata (IMDSv2),
pulls the three repos, and then rebuilds **only what moved**: the venv when
`requirements.txt` changed, the Node subprojects when their lockfiles changed,
the API when its HEAD changed. The frontend is downloaded, not built — CI
publishes Next's standalone output as a release asset, since `next build`
needs most of this box's RAM.

The frontend lands in `frontend/releases/<sha>` with `frontend/current` as a
symlink, so a rollback is a symlink flip. If the health checks fail after a
restart, `deploy.sh` flips it back to the previous release itself and exits
non-zero.

## Why no CORS config

`Caddyfile` puts the frontend and `/api/*` under one hostname, so a request
from the page to `/api/...` is same-origin — no preflight, no `FRONTEND_URL`
mismatch to debug. `FRONTEND_URL` is still set correctly (deploy.sh writes it
into `.deploy-state/public.env`, which the API unit reads) as defence in
depth.

## What this does not cover

- **AWS credentials.** Simplest path: the same `AWS_ACCESS_KEY_ID` /
  `AWS_SECRET_ACCESS_KEY` this dev machine uses, in
  `ai-trader-signals/.env`. Better, once it is worth the half hour: attach an
  IAM instance role with only the Bedrock permissions the app calls — the SDK
  picks it up with no code change, and no long-lived key sits on disk.
- **Log growth.** `journald` is capped by the distro default
  (`SystemMaxUse=` in `/etc/systemd/journald.conf`), which is the cap that now
  applies to every service's logs.
- **Backups.** MongoDB is Atlas, which backs itself up. Redis holds only
  pub-sub traffic and the schedulers' job entries, both rebuilt on start.
