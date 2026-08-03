#!/usr/bin/env bash
# Run this once on a fresh Amazon Linux 2023 / Ubuntu 24.04 EC2 instance.
# Installs Docker, Docker Compose, clones the repo, and starts all services.
#
# Usage:
#   chmod +x setup-ec2.sh && ./setup-ec2.sh

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/YOUR_ORG/ai-trader.git}"
APP_DIR="/opt/ai-trader"

# ── 1. Docker ────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  echo "Installing Docker…"
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
  sudo systemctl enable --now docker
fi

# ── 2. Docker Compose plugin ─────────────────────────────────────────
if ! docker compose version &>/dev/null; then
  echo "Installing Docker Compose plugin…"
  sudo apt-get install -y docker-compose-plugin 2>/dev/null || \
  sudo yum install -y docker-compose-plugin 2>/dev/null || true
fi

# ── 3. Clone / update repo ───────────────────────────────────────────
if [ -d "$APP_DIR/.git" ]; then
  echo "Pulling latest…"
  git -C "$APP_DIR" pull
else
  sudo git clone "$REPO_URL" "$APP_DIR"
  sudo chown -R "$USER:$USER" "$APP_DIR"
fi

cd "$APP_DIR"

# ── 4. .env files ────────────────────────────────────────────────────
echo ""
echo "=== ENV FILES ==="
echo "Copy your .env files before starting:"
echo "  $APP_DIR/ai-trader-api/.env"
echo "  $APP_DIR/ai-trader-signals/.env"
echo "  $APP_DIR/ai-trader-frontend/.env.local  (optional)"
echo ""
echo "Minimum required in ai-trader-api/.env:"
cat <<'EOF'
  MONGODB_URI=mongodb+srv://...
  JWT_SECRET=<random 64-char string>
  JWT_PRIVATE_KEY=...
  JWT_PUBLIC_KEY=...
  GOOGLE_CLIENT_ID=...
  GOOGLE_CLIENT_SECRET=...
  GOOGLE_CALLBACK_URL=https://api.yourdomain.com/api/auth/google/callback
  FRONTEND_URL=https://yourdomain.com
EOF
echo ""
echo "Minimum required in ai-trader-signals/.env:"
cat <<'EOF'
  AWS_REGION=ap-south-1
  AWS_ACCESS_KEY_ID=...
  AWS_SECRET_ACCESS_KEY=...
  SQS_SIGNALS_QUEUE_URL=...
  SQS_TASKS_QUEUE_URL=...
  NEWS_API_KEY=...
  # BEDROCK_API_KEY is auto-generated from AWS credentials — leave blank
EOF

read -rp "Have you copied the .env files? [y/N] " ok
[[ "$ok" =~ ^[Yy]$ ]] || { echo "Aborted. Copy .env files and re-run."; exit 1; }

# ── 5. Build & start ─────────────────────────────────────────────────
docker compose pull --ignore-pull-failures 2>/dev/null || true
docker compose up -d --build

echo ""
echo "✓ Services started:"
docker compose ps
echo ""
echo "Frontend : http://$(curl -s ifconfig.me):3000"
echo "API      : http://$(curl -s ifconfig.me):8000"
echo "Signals  : http://$(curl -s ifconfig.me):8001/health"
