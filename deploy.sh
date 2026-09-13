#!/usr/bin/env bash
# Deploy on the EC2 instance itself. Run from the repo root:
#   ./deploy.sh
#
# What this does that a plain `docker compose up` cannot: resolves the
# instance's own public hostname from EC2's metadata service, which Caddy and
# the API both need. The frontend's copy of that origin is inlined into its JS
# bundle at build time instead, which now happens in CI.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "Resolving this instance's public IP..."
# IMDSv2: a token is required before the metadata service answers anything,
# closing the SSRF-via-metadata-endpoint hole IMDSv1 was open to.
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/public-ipv4)

if [ -z "$PUBLIC_IP" ]; then
  echo "Could not resolve a public IP from instance metadata." >&2
  echo "Is this running on EC2, with a public IP or Elastic IP attached?" >&2
  exit 1
fi

# NOT the EC2-assigned public-hostname: Let's Encrypt flatly refuses to issue
# for *.compute.amazonaws.com (and similar shared-hosting suffixes) — "forbidden
# by policy", found by hitting it live, not by reading docs beforehand. sslip.io
# is free wildcard DNS with no such block: <ip>.sslip.io resolves straight to
# <ip>, and Caddy can get a real, trusted cert for it.
PUBLIC_HOSTNAME="${PUBLIC_IP}.sslip.io"
echo "Public hostname: $PUBLIC_HOSTNAME"

export PUBLIC_HOSTNAME

# Only the three service subdirectories are git repos — this directory itself
# holds the deploy config (Caddyfile, compose files) as loose files, same as
# on the machine that generates them, so there is nothing to pull at this level.
for repo in ai-trader-frontend ai-trader-api ai-trader-signals; do
  echo "Pulling $repo..."
  git -C "$repo" pull --ff-only
done

# ── Python services (systemd, no container) ─────────────────────────────
# Rebuilt only when their inputs change: a pip or npm run on this box costs
# minutes and memory, and the usual deploy changes neither.
STATE=.deploy-state
mkdir -p "$STATE"

sync_if_changed() {   # <file> <state-name> <command...>
  local file=$1 name=$2; shift 2
  local now
  now=$(sha256sum "$file" | cut -d' ' -f1)
  if [ "$now" != "$(cat "$STATE/$name" 2>/dev/null || true)" ]; then
    echo "$file changed — running: $*"
    "$@"
    echo "$now" > "$STATE/$name"
  fi
}

VENV=$PWD/venv-signals
sync_if_changed ai-trader-signals/requirements.txt requirements.sha \
  "$VENV/bin/pip" install -q -r ai-trader-signals/requirements.txt

# The Pine sandbox and the Dukascopy bridge are Node subprojects this
# service spawns as subprocesses; the image used to carry their modules.
for sub in pine_sandbox dukascopy_bridge; do
  sync_if_changed "ai-trader-signals/app/$sub/package-lock.json" "$sub.sha" \
    npm --prefix "ai-trader-signals/app/$sub" ci --omit=dev
done

for unit in systemd/*.service; do
  name=$(basename "$unit")
  if ! sudo cmp -s "$unit" "/etc/systemd/system/$name"; then
    echo "Installing $name"
    sudo install -m 644 "$unit" "/etc/systemd/system/$name"
    RELOAD=1
  fi
done
[ "${RELOAD:-0}" = 1 ] && sudo systemctl daemon-reload

# ── Containers (API, frontend, Caddy, Redis) ────────────────────────────
# Stop before starting the new generation: this box has 2 GB of RAM and
# cannot hold two sets of containers at once. The frontend build that made
# this genuinely dangerous now happens in CI, so this is a short restart
# rather than a build outage.
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.prod.yml"
# --remove-orphans: signals and newsd left the compose file for systemd, and
# their old containers would otherwise keep running against the new code.
$COMPOSE down --remove-orphans
# The frontend image is built in CI and pulled; only the NestJS image is
# still built here, and it needs nothing like the RAM `next build` did.
$COMPOSE pull frontend
$COMPOSE build api
$COMPOSE up -d

# enable: these have to come back on their own after a reboot.
sudo systemctl enable -q ai-trader-signals ai-trader-newsd
sudo systemctl restart ai-trader-signals ai-trader-newsd

# ── Did it actually come back? ──────────────────────────────────────────
for attempt in $(seq 1 20); do
  signals_up=$(curl -fsS -m 5 http://127.0.0.1:8001/health >/dev/null 2>&1 && echo 1 || echo 0)
  api_up=$(curl -fsS -m 5 http://127.0.0.1:8000/api/health >/dev/null 2>&1 && echo 1 || echo 0)
  [ "$signals_up$api_up" = "11" ] && break
  sleep 3
done
if [ "$signals_up$api_up" != "11" ]; then
  echo "Deploy finished but health checks failed (signals=$signals_up api=$api_up)" >&2
  sudo systemctl --no-pager --lines=20 status ai-trader-signals || true
  exit 1
fi
systemctl is-active ai-trader-signals ai-trader-newsd | tr '
' ' '; echo

echo ""
echo "Deployed. https://$PUBLIC_HOSTNAME"
echo ""
echo "First deploy only, still manual:"
echo "  - MongoDB Atlas: allow this instance's IP in Network Access."
echo "  - .env files for each service must already exist on this box (not in git)."
