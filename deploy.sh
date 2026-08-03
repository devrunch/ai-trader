#!/usr/bin/env bash
# Deploy on the EC2 instance itself. Run from the repo root:
#   ./deploy.sh
#
# What this does that a plain `docker compose up` cannot: resolves the
# instance's own public hostname from EC2's metadata service and rebuilds the
# frontend with it baked in. That value cannot be known ahead of time and
# cannot be set at container-start — Next.js inlines NEXT_PUBLIC_API_URL into
# the JS bundle at `next build`, so a stale hostname means every browser
# fetch goes to the wrong origin until the next deploy.
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

# Stop before building, not after: this box has 2GB RAM, and `next build`
# alone can use most of that. Building while the previous generation's five
# containers are still live competing for the same RAM is what took the whole
# instance unresponsive on the first deploy — AWS's own reachability check
# failed, not just the app. A `docker compose down` here costs the deploy a
# minute or two of downtime; for a ≤10-user MVP that is the correct trade
# against the alternative, which was the box needing a manual reboot.
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.prod.yml"
$COMPOSE down
$COMPOSE build
$COMPOSE up -d

echo ""
echo "Deployed. https://$PUBLIC_HOSTNAME"
echo ""
echo "First deploy only, still manual:"
echo "  - MongoDB Atlas: allow this instance's IP in Network Access."
echo "  - .env files for each service must already exist on this box (not in git)."
