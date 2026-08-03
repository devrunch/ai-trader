#!/usr/bin/env bash
# Full deployment script for:
#   - NestJS API  → AWS Lambda (Serverless Framework)
#   - Signals     → AWS ECR + ECS Fargate
#   - Frontend    → Vercel (run separately: `vercel --prod`)
#
# Prerequisites:
#   aws cli v2 configured (aws configure)
#   serverless cli  (npm install -g serverless)
#   docker running
#
# Usage: ./deploy/deploy.sh

set -euo pipefail

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="ap-south-1"
ECR_REPO="ai-trader-signals"
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}"
TAG="${1:-latest}"

echo "▶ Account: $ACCOUNT_ID | Region: $REGION | Tag: $TAG"

# ── 1. Push secrets to SSM (only needed once, or when values change) ─
push_ssm() {
  local name=$1 value=$2
  aws ssm put-parameter \
    --name "/ai-trader/${name}" \
    --value "${value}" \
    --type SecureString \
    --overwrite \
    --region "$REGION" \
    --no-cli-pager
  echo "  SSM: /ai-trader/${name} ✓"
}

if [[ "${PUSH_SECRETS:-false}" == "true" ]]; then
  echo "▶ Pushing secrets to SSM Parameter Store…"
  source ai-trader-api/.env
  push_ssm "api/MONGODB_URI"          "$MONGODB_URI"
  push_ssm "api/JWT_SECRET"           "$JWT_SECRET"
  push_ssm "api/JWT_PRIVATE_KEY"      "$JWT_PRIVATE_KEY"
  push_ssm "api/JWT_PUBLIC_KEY"       "$JWT_PUBLIC_KEY"
  push_ssm "api/GOOGLE_CLIENT_ID"     "$GOOGLE_CLIENT_ID"
  push_ssm "api/GOOGLE_CLIENT_SECRET" "$GOOGLE_CLIENT_SECRET"
  push_ssm "api/GOOGLE_CALLBACK_URL"  "$GOOGLE_CALLBACK_URL"
  push_ssm "api/FRONTEND_URL"         "$FRONTEND_URL"
  push_ssm "api/SIGNALS_SERVICE_URL"  "$SIGNALS_SERVICE_URL"

  source ai-trader-signals/.env
  push_ssm "signals/SQS_SIGNALS_QUEUE_URL" "$SQS_SIGNALS_QUEUE_URL"
  push_ssm "signals/SQS_TASKS_QUEUE_URL"   "$SQS_TASKS_QUEUE_URL"
  push_ssm "signals/NEWS_API_KEY"          "$NEWS_API_KEY"
fi

# ── 2. Deploy NestJS API → Lambda ────────────────────────────────────
echo ""
echo "▶ Building & deploying NestJS API to Lambda…"
cd ai-trader-api
npm run build
npx serverless deploy --region "$REGION" --verbose
API_URL=$(npx serverless info --verbose 2>/dev/null | grep "HttpApiUrl" | awk '{print $2}' || echo "check AWS console")
echo "  API URL: $API_URL"
cd ..

# ── 3. Build & push signals image to ECR ─────────────────────────────
echo ""
echo "▶ Building signals Docker image…"
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# Create ECR repo if it doesn't exist
aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$REGION" &>/dev/null || \
  aws ecr create-repository --repository-name "$ECR_REPO" --region "$REGION" --no-cli-pager

docker build \
  --target api \
  -f docker/signals/Dockerfile \
  -t "${ECR_URI}:${TAG}" \
  ai-trader-signals/

docker push "${ECR_URI}:${TAG}"
echo "  Image: ${ECR_URI}:${TAG} ✓"

# ── 4. Update Fargate task definitions ──────────────────────────────
echo ""
echo "▶ Registering ECS task definitions…"

# Substitute account ID into task definitions
for f in deploy/fargate/signals-task.json deploy/fargate/worker-task.json; do
  sed "s/YOUR_ACCOUNT_ID/${ACCOUNT_ID}/g; s|ai-trader-signals:latest|${ECR_URI}:${TAG}|g" "$f" > /tmp/task.json
  aws ecs register-task-definition --cli-input-json file:///tmp/task.json --region "$REGION" --no-cli-pager
  echo "  $(basename $f) ✓"
done

# ── 5. Update running ECS services (if they exist) ──────────────────
echo ""
echo "▶ Updating ECS services…"
for svc in ai-trader-signals ai-trader-worker; do
  if aws ecs describe-services --cluster ai-trader --services "$svc" --region "$REGION" \
       --query 'services[0].status' --output text 2>/dev/null | grep -q ACTIVE; then
    aws ecs update-service \
      --cluster ai-trader \
      --service "$svc" \
      --force-new-deployment \
      --region "$REGION" \
      --no-cli-pager
    echo "  $svc redeployed ✓"
  else
    echo "  $svc not found — create it in ECS console using task definitions above"
  fi
done

echo ""
echo "═══════════════════════════════════════════════"
echo "  Deployment complete"
echo "  API Lambda : $API_URL"
echo "  Signals ECR: ${ECR_URI}:${TAG}"
echo ""
echo "  Frontend → run:  cd ai-trader-frontend && vercel --prod"
echo "═══════════════════════════════════════════════"
