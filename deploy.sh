#!/usr/bin/env bash
# Deploy on the EC2 instance itself. Run from the repo root:
#   ./deploy.sh
#
# Every service is a systemd unit; there is no container runtime on this box.
# What this does that `systemctl restart` cannot: resolve the instance's own
# public hostname (Caddy and the API both need it), rebuild only what actually
# changed, install the frontend bundle CI built, and put the previous frontend
# back if the new one does not answer.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT=$PWD
STATE=$ROOT/.deploy-state
mkdir -p "$STATE"

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

# The units read this; nothing may hardcode a hostname that only exists once
# the instance is running.
printf 'PUBLIC_HOSTNAME=%s\nFRONTEND_URL=https://%s\n' "$PUBLIC_HOSTNAME" "$PUBLIC_HOSTNAME" \
  > "$STATE/public.env"

# Only the three service subdirectories are git repos — this directory itself
# holds the deploy config (Caddyfile, units) as loose files, same as on the
# machine that generates them, so there is nothing to pull at this level.
# Remembered before the pull: the rollback path below checks these back out.
PREVIOUS_API=$(git -C ai-trader-api rev-parse HEAD)
PREVIOUS_SIGNALS=$(git -C ai-trader-signals rev-parse HEAD)
for repo in ai-trader-frontend ai-trader-api ai-trader-signals; do
  echo "Pulling $repo..."
  git -C "$repo" pull --ff-only
done

# ── Rebuild only what moved ─────────────────────────────────────────────────
# A pip or npm run on this box costs minutes and memory, and the usual deploy
# changes neither set of dependencies.
changed() {   # <file-or-sha> <state-name>; true when different from last deploy
  local now=$1 name=$2
  [ "$now" != "$(cat "$STATE/$name" 2>/dev/null || true)" ]
}
remember() { echo "$1" > "$STATE/$2"; }

REQ_SHA=$(sha256sum ai-trader-signals/requirements.txt | cut -d' ' -f1)
if changed "$REQ_SHA" requirements.sha; then
  echo "requirements.txt changed — syncing the venv"
  "$ROOT/venv-signals/bin/pip" install -q -r ai-trader-signals/requirements.txt
  remember "$REQ_SHA" requirements.sha
fi

# The Pine sandbox and the Dukascopy bridge are Node subprojects the signals
# service spawns as subprocesses.
for sub in pine_sandbox dukascopy_bridge; do
  SUB_SHA=$(sha256sum "ai-trader-signals/app/$sub/package-lock.json" | cut -d' ' -f1)
  if changed "$SUB_SHA" "$sub.sha"; then
    echo "$sub lockfile changed — npm ci"
    npm --prefix "ai-trader-signals/app/$sub" ci --omit=dev
    remember "$SUB_SHA" "$sub.sha"
  fi
done

API_SHA=$(git -C ai-trader-api rev-parse HEAD)
if changed "$API_SHA" api.sha; then
  echo "API moved — installing and building"
  npm --prefix ai-trader-api ci
  npm --prefix ai-trader-api run build
  # Dev dependencies (TypeScript, Nest CLI) are build-time only and are a few
  # hundred MB of disk this box would rather keep.
  npm --prefix ai-trader-api prune --omit=dev
  remember "$API_SHA" api.sha
fi

# ── The frontend bundle CI built ────────────────────────────────────────────
# `next build` needs most of this box's 2 GB, which is what made every deploy a
# full outage. CI publishes the standalone output as a release asset instead;
# the repo is public, so no credentials are involved.
BUNDLE_URL=https://github.com/devrunch/ai-trader-frontend/releases/download/bundle/frontend.tar.gz
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PREVIOUS_FRONTEND=$(readlink -f "$ROOT/frontend/current" 2>/dev/null || true)
if curl -fsSL -o "$TMP/frontend.tar.gz" "$BUNDLE_URL"; then
  tar xzf "$TMP/frontend.tar.gz" -C "$TMP" ./COMMIT
  BUNDLE_SHA=$(cat "$TMP/COMMIT")
  if changed "$BUNDLE_SHA" frontend.sha; then
    echo "New frontend bundle: $BUNDLE_SHA"
    mkdir -p "$ROOT/frontend/releases/$BUNDLE_SHA"
    tar xzf "$TMP/frontend.tar.gz" -C "$ROOT/frontend/releases/$BUNDLE_SHA"
    ln -sfn "$ROOT/frontend/releases/$BUNDLE_SHA" "$ROOT/frontend/current"
    remember "$BUNDLE_SHA" frontend.sha
    # Two older releases stay, so a rollback has somewhere to go.
    ls -1dt "$ROOT/frontend/releases"/*/ | tail -n +4 | xargs -r rm -rf
  fi
else
  echo "Could not fetch the frontend bundle — keeping the installed one." >&2
fi

# ── Units ───────────────────────────────────────────────────────────────────
for unit in systemd/*.service; do
  name=$(basename "$unit")
  if ! sudo cmp -s "$unit" "/etc/systemd/system/$name"; then
    echo "Installing $name"
    sudo install -m 644 "$unit" "/etc/systemd/system/$name"
    RELOAD=1
  fi
done
# Caddy is packaged, so its hostname arrives as a drop-in rather than a unit.
CADDY_DROPIN=/etc/systemd/system/caddy.service.d/public-hostname.conf
sudo mkdir -p "$(dirname "$CADDY_DROPIN")"
if ! printf '[Service]\nEnvironment=PUBLIC_HOSTNAME=%s\n' "$PUBLIC_HOSTNAME" | sudo cmp -s - "$CADDY_DROPIN"; then
  printf '[Service]\nEnvironment=PUBLIC_HOSTNAME=%s\n' "$PUBLIC_HOSTNAME" | sudo tee "$CADDY_DROPIN" >/dev/null
  RELOAD=1
fi
if ! sudo cmp -s Caddyfile /etc/caddy/Caddyfile; then
  sudo install -m 644 Caddyfile /etc/caddy/Caddyfile
  CADDY_CHANGED=1
fi
[ "${RELOAD:-0}" = 1 ] && sudo systemctl daemon-reload

sudo systemctl enable -q ai-trader-signals ai-trader-newsd ai-trader-api ai-trader-frontend
sudo systemctl restart ai-trader-api ai-trader-frontend ai-trader-signals ai-trader-newsd
[ "${RELOAD:-0}${CADDY_CHANGED:-0}" = "00" ] || sudo systemctl restart caddy

# ── Did it actually come back? ──────────────────────────────────────────────
healthy() {
  curl -fsS -m 5 http://127.0.0.1:8001/health   >/dev/null 2>&1 &&
  curl -fsS -m 5 http://127.0.0.1:8000/api/health >/dev/null 2>&1 &&
  curl -fsS -m 5 -o /dev/null http://127.0.0.1:3000/ 2>/dev/null
}
for _ in $(seq 1 20); do healthy && break; sleep 3; done

if ! healthy; then
  echo "Health checks failed after the deploy — rolling back." >&2

  if [ -n "$PREVIOUS_FRONTEND" ] && [ -d "$PREVIOUS_FRONTEND" ]; then
    echo "Frontend back to $(basename "$PREVIOUS_FRONTEND")" >&2
    ln -sfn "$PREVIOUS_FRONTEND" "$ROOT/frontend/current"
    remember "$(basename "$PREVIOUS_FRONTEND")" frontend.sha
  fi

  # The Python service runs from the working tree, so checking the commit
  # out is the whole rollback; the API has to be rebuilt from it.
  git -C ai-trader-signals reset -q --hard "$PREVIOUS_SIGNALS"
  if [ "$(git -C ai-trader-api rev-parse HEAD)" != "$PREVIOUS_API" ]; then
    git -C ai-trader-api reset -q --hard "$PREVIOUS_API"
    npm --prefix ai-trader-api ci
    npm --prefix ai-trader-api run build
    npm --prefix ai-trader-api prune --omit=dev
    remember "$PREVIOUS_API" api.sha
  fi

  sudo systemctl restart ai-trader-api ai-trader-frontend ai-trader-signals ai-trader-newsd
  for _ in $(seq 1 20); do healthy && break; sleep 3; done

  if healthy; then
    echo "Rolled back to the previous release — this deploy did not ship." >&2
  else
    echo "Rollback did not restore health either. The box needs a human." >&2
    sudo systemctl --no-pager --lines=20 status ai-trader-api ai-trader-frontend ai-trader-signals || true
  fi
  exit 1
fi

systemctl is-active ai-trader-signals ai-trader-newsd ai-trader-api ai-trader-frontend caddy redis-server | tr '\n' ' '; echo
echo ""
echo "Deployed. https://$PUBLIC_HOSTNAME"
echo ""
echo "First deploy only, still manual:"
echo "  - MongoDB Atlas: allow this instance's IP in Network Access."
echo "  - .env files for each service must already exist on this box (not in git)."
