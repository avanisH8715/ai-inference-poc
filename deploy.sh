#!/usr/bin/env bash
# =============================================================================
# NeuralChat — One-Shot Deployment Script
#
# Runs end-to-end with no manual steps:
#   1. Creates security group (idempotent)
#   2. Launches EC2 builder, installs Ollama + models via user-data (no SSH)
#   3. Polls /health until inference server is up (~15 min)
#   4. Snapshots EC2 into AMI, terminates the builder
#   5. Creates IAM role for Lambda
#   6. Packages and deploys Lambda function
#   7. Creates public Function URL with CORS
#
# Prerequisites:
#   - AWS CLI v2 configured  (aws configure)
#   - python3 and zip installed locally
#
# Usage:
#   chmod +x deploy.sh
#   ./deploy.sh
#
# Optional env var overrides:
#   REGION=us-west-2 KEY_NAME=mykey INSTANCE_TYPE=t3.2xlarge ./deploy.sh
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
REGION="${REGION:-us-east-1}"
KEY_NAME="${KEY_NAME:-}"
BUILD_INSTANCE_TYPE="${INSTANCE_TYPE:-t3.2xlarge}"
DISK_GB=60
AMI_NAME="neuralchat-inference-v1"
SG_NAME="neuralchat-inference-sg"
ROLE_NAME="NeuralChatLambdaRole"
FUNCTION_NAME="neuralchat-inference"
INFERENCE_PORT=8000
HEALTH_TIMEOUT=1800    # 30-min ceiling for model pulls + service start
HEALTH_INTERVAL=20
AMI_POLL_TIMEOUT=1800  # 30-min ceiling for AMI snapshot
LAMBDA_TIMEOUT=900
LAMBDA_MEMORY=256

# Models pre-pulled into the AMI (edit to add/remove)
# Each is stored permanently — no re-download on each inference request
MODELS=("llama3.2:1b" "llama3.2:3b" "phi3:mini" "gemma2:2b")

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'
BLU='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()  { printf "${BLU}[%s]${NC} %s\n"       "$(date +%H:%M:%S)" "$*"; }
ok()   { printf "${GRN}✓${NC} %s\n"           "$*"; }
warn() { printf "${YEL}⚠${NC} %s\n"           "$*"; }
step() { printf "\n${BOLD}${BLU}──── %s ────${NC}\n" "$*"; }
die()  { printf "${RED}✗ FATAL:${NC} %s\n"    "$*" >&2; exit 1; }

# ── Terminate builder on unexpected exit ──────────────────────────────────────
BUILDER_ID=""
_cleanup() {
  if [[ -n "$BUILDER_ID" ]]; then
    warn "Terminating builder $BUILDER_ID (cleanup on exit)..."
    aws ec2 terminate-instances --instance-ids "$BUILDER_ID" \
      --region "$REGION" >/dev/null 2>&1 || true
  fi
}
trap _cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════════════
step "0. Prerequisites"

command -v aws     >/dev/null || die "AWS CLI not installed — https://aws.amazon.com/cli/"
command -v python3 >/dev/null || die "python3 not installed"
command -v zip     >/dev/null || die "zip not installed"

[[ -f "lambda/lambda_function.py" ]] \
  || die "Run from repo root — expected lambda/lambda_function.py"
[[ -f "ec2-setup/inference_server.py" ]] \
  || die "Missing ec2-setup/inference_server.py"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ok "Account: $ACCOUNT_ID | Region: $REGION"

# ═══════════════════════════════════════════════════════════════════════════════
step "1. Security group (TCP $INFERENCE_PORT)"

VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].VpcId' --output text --region "$REGION")

SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text \
  --region "$REGION" 2>/dev/null || true)

if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
  SG_ID=$(aws ec2 create-security-group \
    --group-name  "$SG_NAME" \
    --description "NeuralChat — TCP $INFERENCE_PORT for AI inference" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text --region "$REGION")

  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" --protocol tcp \
    --port "$INFERENCE_PORT" --cidr 0.0.0.0/0 \
    --region "$REGION" >/dev/null

  ok "Created: $SG_ID"
else
  ok "Reusing existing SG: $SG_ID"
fi

# ═══════════════════════════════════════════════════════════════════════════════
step "2. AMI"

AMI_ID=$(aws ec2 describe-images \
  --owners self \
  --filters "Name=name,Values=$AMI_NAME" "Name=state,Values=available" \
  --query 'Images[0].ImageId' --output text \
  --region "$REGION" 2>/dev/null || true)

if [[ -n "$AMI_ID" && "$AMI_ID" != "None" ]]; then
  ok "AMI already exists ($AMI_ID) — skipping build"
  warn "To force a rebuild: aws ec2 deregister-image --image-id $AMI_ID --region $REGION"
else

  # ── 2a. Find latest Ubuntu 22.04 AMI ───────────────────────────────────────
  UBUNTU_AMI=$(aws ec2 describe-images \
    --owners 099720109477 \
    --filters \
      "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-*" \
      "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text --region "$REGION")
  ok "Ubuntu 22.04 base AMI: $UBUNTU_AMI"

  # ── 2b. Build user-data (no SSH required — full setup runs on first boot) ──
  step "2b. Generating user-data setup script"
  MODELS_STR="${MODELS[*]}"
  TMP_UD=$(mktemp /tmp/nc-userdata-XXXXXX.sh)

  # Part 1 — system + Ollama
  cat > "$TMP_UD" << 'BASH_P1'
#!/bin/bash
set -euo pipefail
exec > /var/log/neuralchat-setup.log 2>&1
echo "=== NeuralChat setup start: $(date) ==="

apt-get update -y
apt-get install -y curl python3 python3-pip python3-venv

echo "Installing Ollama..."
curl -fsSL https://ollama.com/install.sh | sh
systemctl enable ollama && systemctl start ollama

echo "Waiting for Ollama API..."
for i in $(seq 1 40); do
  curl -sf http://localhost:11434/api/tags >/dev/null 2>&1 && { echo "Ollama ready."; break; }
  sleep 5
done

echo "Pulling models..."
BASH_P1

  # Part 2 — model list (substituted from local MODELS array)
  {
    echo "for model in $MODELS_STR; do"
    echo '  echo "  -> $model"'
    echo '  ollama pull "$model" || echo "WARNING: pull failed for $model"'
    echo 'done'
    echo 'echo "Installed models:"; ollama list'
  } >> "$TMP_UD"

  # Part 3 — Python venv + start of inference_server.py embed
  cat >> "$TMP_UD" << 'BASH_P3'

echo "Setting up Python venv..."
python3 -m venv /opt/neuralchat-venv
/opt/neuralchat-venv/bin/pip install --upgrade pip -q

mkdir -p /opt/neuralchat
echo "Writing inference server..."
cat > /opt/neuralchat/inference_server.py << 'NC_INFERENCE_EOF'
BASH_P3

  # Embed inference_server.py verbatim (no base64 — heredoc handles it cleanly)
  cat ec2-setup/inference_server.py >> "$TMP_UD"

  # Part 4 — close heredoc + systemd service + done signal
  cat >> "$TMP_UD" << 'BASH_P4'
NC_INFERENCE_EOF

cat > /etc/systemd/system/neuralchat.service << 'SVCEOF'
[Unit]
Description=NeuralChat Inference Server
After=network.target ollama.service
Requires=ollama.service

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/opt/neuralchat
ExecStart=/opt/neuralchat-venv/bin/python3 /opt/neuralchat/inference_server.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=neuralchat

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable neuralchat
systemctl start neuralchat

echo "=== NeuralChat setup complete: $(date) ==="
BASH_P4

  ok "User-data script: $(wc -l < "$TMP_UD") lines, $(wc -c < "$TMP_UD") bytes"

  # ── 2c. Launch builder EC2 ─────────────────────────────────────────────────
  step "2c. Launching builder EC2 ($BUILD_INSTANCE_TYPE, ${DISK_GB} GB)"

  RUN_ARGS=(
    --image-id "$UBUNTU_AMI"
    --instance-type "$BUILD_INSTANCE_TYPE"
    --min-count 1 --max-count 1
    --block-device-mappings \
      "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":$DISK_GB,\"VolumeType\":\"gp3\"}}]"
    --network-interfaces \
      "[{\"DeviceIndex\":0,\"AssociatePublicIpAddress\":true,\"Groups\":[\"$SG_ID\"]}]"
    --user-data "file://$TMP_UD"
    --tag-specifications \
      "ResourceType=instance,Tags=[{Key=Name,Value=neuralchat-ami-builder},{Key=Purpose,Value=neuralchat-deploy}]"
    --query 'Instances[0].InstanceId'
    --output text
    --region "$REGION"
  )
  [[ -n "$KEY_NAME" ]] && RUN_ARGS+=(--key-name "$KEY_NAME")

  BUILDER_ID=$(aws ec2 run-instances "${RUN_ARGS[@]}")
  rm -f "$TMP_UD"
  ok "Builder launched: $BUILDER_ID"

  # ── 2d. Wait for running state + public IP ─────────────────────────────────
  step "2d. Waiting for EC2 running state"
  aws ec2 wait instance-running \
    --instance-ids "$BUILDER_ID" --region "$REGION"

  PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$BUILDER_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text --region "$REGION")
  ok "EC2 running | Public IP: $PUBLIC_IP"

  # ── 2e. Poll /health until inference server is ready ──────────────────────
  step "2e. Waiting for inference server to come up (~15 min while models pull)"
  HEALTH_URL="http://${PUBLIC_IP}:${INFERENCE_PORT}/health"
  T_START=$(date +%s)
  T_END=$(( T_START + HEALTH_TIMEOUT ))
  ATTEMPT=0
  HTTP_STATUS="000"

  while (( $(date +%s) < T_END )); do
    ATTEMPT=$(( ATTEMPT + 1 ))
    HTTP_STATUS=$(curl -sf --connect-timeout 5 --max-time 8 \
      -o /dev/null -w '%{http_code}' "$HEALTH_URL" 2>/dev/null || echo "000")

    if [[ "$HTTP_STATUS" == "200" ]]; then
      echo ""
      ok "Health check passed (attempt $ATTEMPT, $(( $(date +%s) - T_START ))s elapsed)"
      break
    fi

    ELAPSED=$(( $(date +%s) - T_START ))
    printf "\r${BLU}[%s]${NC} %dm%02ds elapsed — attempt %d (HTTP %s)   " \
      "$(date +%H:%M:%S)" \
      "$(( ELAPSED / 60 ))" "$(( ELAPSED % 60 ))" \
      "$ATTEMPT" "$HTTP_STATUS"
    sleep "$HEALTH_INTERVAL"
  done
  echo ""

  [[ "$HTTP_STATUS" == "200" ]] \
    || die "Server never healthy after ${HEALTH_TIMEOUT}s.
       SSH in and check: sudo journalctl -u neuralchat -n 50
       Setup log:        sudo cat /var/log/neuralchat-setup.log"

  # ── 2f. Create AMI ─────────────────────────────────────────────────────────
  step "2f. Snapshotting EC2 into AMI"
  AMI_ID=$(aws ec2 create-image \
    --instance-id "$BUILDER_ID" \
    --name "$AMI_NAME" \
    --description "NeuralChat: Ollama + pre-pulled models" \
    --no-reboot \
    --query 'ImageId' --output text \
    --region "$REGION")
  ok "AMI snapshot started: $AMI_ID"

  log "Waiting for AMI to become available (typically 5–10 min)..."
  AMI_T_END=$(( $(date +%s) + AMI_POLL_TIMEOUT ))
  AMI_STATE=""
  while (( $(date +%s) < AMI_T_END )); do
    AMI_STATE=$(aws ec2 describe-images --image-ids "$AMI_ID" \
      --query 'Images[0].State' --output text --region "$REGION" 2>/dev/null || echo "pending")
    [[ "$AMI_STATE" == "available" ]] && { echo ""; ok "AMI available: $AMI_ID"; break; }
    [[ "$AMI_STATE" == "failed"    ]] && { echo ""; die "AMI creation failed. Check EC2 console."; }
    printf "\r${BLU}[%s]${NC} AMI state: %s...   " "$(date +%H:%M:%S)" "$AMI_STATE"
    sleep 20
  done
  [[ "$AMI_STATE" == "available" ]] || die "AMI did not become available in ${AMI_POLL_TIMEOUT}s"

  # ── 2g. Terminate builder ──────────────────────────────────────────────────
  aws ec2 terminate-instances --instance-ids "$BUILDER_ID" \
    --region "$REGION" >/dev/null
  ok "Builder $BUILDER_ID terminated"
  BUILDER_ID=""  # prevent double-terminate in trap

fi  # end AMI build block

# ═══════════════════════════════════════════════════════════════════════════════
step "3. IAM role for Lambda"

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" \
  --query 'Role.Arn' --output text 2>/dev/null || true)

if [[ -z "$ROLE_ARN" || "$ROLE_ARN" == "None" ]]; then
  TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
    "Principal":{"Service":"lambda.amazonaws.com"},
    "Action":"sts:AssumeRole"}]}'

  ROLE_ARN=$(aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST" \
    --query 'Role.Arn' --output text)

  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

  EC2_POL='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":
    ["ec2:RunInstances","ec2:DescribeInstances","ec2:TerminateInstances",
     "ec2:CreateTags","ec2:DescribeSubnets","ec2:DescribeSecurityGroups"],
    "Resource":"*"}]}'

  aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name EC2InferenceAccess \
    --policy-document "$EC2_POL"

  ok "IAM role created: $ROLE_ARN"
  log "Waiting 20s for IAM to propagate across regions..."
  sleep 20
else
  ok "Reusing existing IAM role: $ROLE_ARN"
fi

# ═══════════════════════════════════════════════════════════════════════════════
step "4. Packaging Lambda"

SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=defaultForAz,Values=true" \
  --query 'Subnets[0].SubnetId' --output text --region "$REGION")
ok "Subnet: $SUBNET_ID"

cd lambda/
zip -q function.zip lambda_function.py
ok "Packaged lambda/function.zip"
cd ..

# ═══════════════════════════════════════════════════════════════════════════════
step "5. Deploying Lambda function"

ENV="Variables={\
AMI_ID=$AMI_ID,\
SECURITY_GROUP_ID=$SG_ID,\
SUBNET_ID=$SUBNET_ID,\
AWS_REGION_NAME=$REGION,\
INFERENCE_PORT=$INFERENCE_PORT}"

FN_ARN=$(aws lambda get-function \
  --function-name "$FUNCTION_NAME" --region "$REGION" \
  --query 'Configuration.FunctionArn' --output text 2>/dev/null || true)

if [[ -n "$FN_ARN" && "$FN_ARN" != "None" ]]; then
  warn "Lambda exists — updating code and configuration"

  aws lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --zip-file fileb://lambda/function.zip \
    --region "$REGION" >/dev/null
  aws lambda wait function-updated \
    --function-name "$FUNCTION_NAME" --region "$REGION"

  aws lambda update-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --timeout "$LAMBDA_TIMEOUT" \
    --memory-size "$LAMBDA_MEMORY" \
    --environment "$ENV" \
    --region "$REGION" >/dev/null
  aws lambda wait function-updated \
    --function-name "$FUNCTION_NAME" --region "$REGION"

  ok "Lambda updated"
else
  aws lambda create-function \
    --function-name "$FUNCTION_NAME" \
    --runtime python3.12 \
    --role "$ROLE_ARN" \
    --handler lambda_function.lambda_handler \
    --zip-file fileb://lambda/function.zip \
    --timeout "$LAMBDA_TIMEOUT" \
    --memory-size "$LAMBDA_MEMORY" \
    --environment "$ENV" \
    --region "$REGION" >/dev/null
  aws lambda wait function-updated \
    --function-name "$FUNCTION_NAME" --region "$REGION"

  ok "Lambda created"
fi

# ═══════════════════════════════════════════════════════════════════════════════
step "6. Lambda Function URL"

CORS='{"AllowOrigins":["*"],"AllowMethods":["POST","OPTIONS"],
  "AllowHeaders":["Content-Type"],"MaxAge":86400}'

LAMBDA_URL=$(aws lambda get-function-url-config \
  --function-name "$FUNCTION_NAME" --region "$REGION" \
  --query 'FunctionUrl' --output text 2>/dev/null || true)

if [[ -n "$LAMBDA_URL" && "$LAMBDA_URL" != "None" ]]; then
  aws lambda update-function-url-config \
    --function-name "$FUNCTION_NAME" \
    --cors "$CORS" \
    --region "$REGION" >/dev/null
  ok "Function URL updated: $LAMBDA_URL"
else
  LAMBDA_URL=$(aws lambda create-function-url-config \
    --function-name "$FUNCTION_NAME" \
    --auth-type NONE \
    --cors "$CORS" \
    --region "$REGION" \
    --query 'FunctionUrl' --output text)

  # Allow unauthenticated public invocations — ignore if permission already set
  aws lambda add-permission \
    --function-name "$FUNCTION_NAME" \
    --action lambda:InvokeFunctionUrl \
    --principal '*' \
    --function-url-auth-type NONE \
    --statement-id allow-public-url \
    --region "$REGION" >/dev/null 2>&1 || true

  ok "Function URL created: $LAMBDA_URL"
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
printf "${GRN}${BOLD}╔══════════════════════════════════════════════════════════════╗\n${NC}"
printf "${GRN}${BOLD}║           NeuralChat deployment complete!                    ║\n${NC}"
printf "${GRN}${BOLD}╚══════════════════════════════════════════════════════════════╝\n${NC}"
echo ""
printf "  %-20s %s\n" "AMI:"            "$AMI_ID"
printf "  %-20s %s\n" "Security Group:" "$SG_ID"
printf "  %-20s %s\n" "IAM Role:"       "$ROLE_NAME"
printf "  %-20s %s\n" "Lambda:"         "$FUNCTION_NAME"
printf "  %-20s %s\n" "Function URL:"   "$LAMBDA_URL"
echo ""
printf "${YEL}Next steps:${NC}\n"
echo "  1. Open index.html → Settings → paste the Function URL above → Save"
echo "  2. Quick end-to-end test:"
echo ""
echo "       curl -X POST \"$LAMBDA_URL\" \\"
echo "         -H 'Content-Type: application/json' \\"
echo "         -d '{\"model\":\"llama3.2:1b\",\"prompt\":\"Hello! What can you do?\"}'"
echo ""

trap - EXIT
