# NeuralChat — AI Inference POC

A full-stack AI chatbot with a beautiful web UI that routes prompts through **AWS Lambda → on-demand EC2 → Ollama LLM** and displays detailed timing metrics for every request.

**Live demo:** deployed via GitHub Pages (see Setup → Step 6)

---

## Architecture

```
Browser (GitHub Pages / Netlify)
  │
  │  POST /  { model, prompt, image? }
  ▼
AWS Lambda (Function URL, public HTTPS)
  │
  ├─ RunInstances → EC2 from AMI
  │  └─ EC2 boots, systemd starts Ollama + inference server
  │
  ├─ Poll GET /health (EC2:8000) until 200
  │
  ├─ POST /inference → Ollama /api/generate
  │
  ├─ Returns { response, timing }
  │
  └─ TerminateInstances (always, in finally block)
  │
  ▼
Browser shows response + timing breakdown
```

---

## Prerequisites

- AWS account with billing enabled
- AWS CLI v2 configured (`aws configure`)
- `python3` and `zip` installed locally
- `gh` CLI installed and authenticated (`gh auth login`) — for GitHub Pages deploy only

---

## Quick Start — Automated Deployment

> One command deploys everything: security group, AMI, IAM role, Lambda, and Function URL.
> No SSH, no manual steps, fully idempotent (safe to re-run).

> 📘 **For a deeper walkthrough** of Lambda code, config, AMI creation, and request/response timing, see **[DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md)**.

```bash
chmod +x deploy.sh
./deploy.sh
```

**What it does, in order:**

| Step | Action | Time |
|------|--------|------|
| 1 | Creates security group (TCP 8000), reuses if it exists | ~5s |
| 2 | Finds latest Ubuntu 22.04 AMI | ~5s |
| 3 | Launches EC2 builder, runs full Ollama + model setup via user-data | ~2 min |
| 4 | Polls `/health` every 20s until inference server is ready | ~15 min |
| 5 | Snapshots EC2 into a reusable AMI, terminates the builder | ~10 min |
| 6 | Creates IAM role with EC2 + CloudWatch permissions | ~20s |
| 7 | Packages and creates (or updates) the Lambda function | ~30s |
| 8 | Creates public Function URL with CORS | ~10s |

**Total: ~30 min on first run. Subsequent runs skip the AMI step and finish in ~2 min.**

**Optional env var overrides:**

```bash
# Different region
REGION=us-west-2 ./deploy.sh

# Add an EC2 key pair for SSH debugging during AMI build
KEY_NAME=my-keypair ./deploy.sh

# Larger instance for 7B+ models
INSTANCE_TYPE=t3.2xlarge KEY_NAME=my-keypair ./deploy.sh
```

Once the script finishes, copy the **Function URL** printed at the end,
open `index.html` → Settings → paste it → Save.

---

## Manual Setup Reference

> The steps below explain each piece in detail.
> Use these if you want to customise the deployment or debug individual stages.
> For a fresh install, prefer `./deploy.sh` above.

---

## Step 1 — Create the EC2 AMI

This step takes 10–20 minutes and only needs to be done once.

### 1a. Launch a setup instance

```bash
# Find the latest Ubuntu 22.04 AMI in your region
aws ec2 describe-images \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-*" \
            "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text \
  --region us-east-1

# Launch the setup instance (t3.2xlarge = 8 vCPU / 32 GB — enough for 7B models)
aws ec2 run-instances \
  --image-id <UBUNTU_AMI_FROM_ABOVE> \
  --instance-type t3.2xlarge \
  --key-name <YOUR_KEY_PAIR> \
  --security-group-ids <SG_THAT_ALLOWS_SSH_22> \
  --associate-public-ip-address \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":50,"VolumeType":"gp3"}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=neuralchat-ami-builder}]' \
  --region us-east-1
```

> **Disk**: 50 GB minimum for small models. Use 100 GB if pulling 7B+ models.

### 1b. SSH into the instance and run the setup script

```bash
# Copy setup files
scp -i ~/.ssh/<YOUR_KEY>.pem \
  ec2-setup/setup_ami.sh \
  ec2-setup/inference_server.py \
  ubuntu@<EC2_PUBLIC_IP>:~/

# SSH in
ssh -i ~/.ssh/<YOUR_KEY>.pem ubuntu@<EC2_PUBLIC_IP>

# Inside EC2 — run setup (takes 10-20 min depending on models)
chmod +x setup_ami.sh
sudo ./setup_ami.sh
```

### 1c. Verify the server is running

```bash
# Inside EC2
curl http://localhost:8000/health
# Expected: {"status":"ok"}

# Test inference
curl -X POST http://localhost:8000/inference \
  -H 'Content-Type: application/json' \
  -d '{"model":"llama3.2:3b","prompt":"Say hello in one sentence."}'
# Expected: {"response":"Hello! ..."}
```

### 1d. Create the AMI

**Option A — AWS Console:**
1. Go to EC2 → Instances
2. Select your instance → Actions → Image and templates → **Create image**
3. Image name: `neuralchat-inference-v1`
4. Check "No reboot" if you want faster creation
5. Click **Create image**
6. Go to EC2 → AMIs → wait for status = **available**
7. **Copy the AMI ID** — you'll need it for Lambda

**Option B — AWS CLI:**
```bash
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=neuralchat-ami-builder" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

aws ec2 create-image \
  --instance-id $INSTANCE_ID \
  --name "neuralchat-inference-v1" \
  --no-reboot \
  --region us-east-1

# Note the returned ami-xxxxxxxxxxxxxxxxx
```

### 1e. Stop or terminate the setup instance

```bash
aws ec2 terminate-instances --instance-ids <SETUP_INSTANCE_ID>
```

---

## Step 2 — Create Security Group for EC2

Lambda needs to reach port 8000 on the EC2 instance.

```bash
# Get your VPC ID
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].VpcId' --output text)

# Create security group
SG_ID=$(aws ec2 create-security-group \
  --group-name "neuralchat-inference-sg" \
  --description "Allow port 8000 for AI inference" \
  --vpc-id $VPC_ID \
  --query 'GroupId' --output text)

echo "Security Group ID: $SG_ID"

# Allow inbound port 8000 from anywhere (tighten for production)
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 8000 \
  --cidr 0.0.0.0/0

# Allow outbound (needed for Ollama to pull models if not pre-pulled)
aws ec2 authorize-security-group-egress \
  --group-id $SG_ID \
  --protocol -1 \
  --cidr 0.0.0.0/0 2>/dev/null || true

echo "SG ready: $SG_ID"
```

---

## Step 3 — Create IAM Role for Lambda

```bash
# Create trust policy
cat > /tmp/lambda-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "lambda.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

# Create role
aws iam create-role \
  --role-name NeuralChatLambdaRole \
  --assume-role-policy-document file:///tmp/lambda-trust.json

# Attach managed policies
aws iam attach-role-policy \
  --role-name NeuralChatLambdaRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

# Create inline policy for EC2 operations
cat > /tmp/ec2-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:DescribeInstances",
        "ec2:TerminateInstances",
        "ec2:CreateTags",
        "ec2:DescribeSubnets",
        "ec2:DescribeSecurityGroups"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name NeuralChatLambdaRole \
  --policy-name EC2InferenceAccess \
  --policy-document file:///tmp/ec2-policy.json

# Get role ARN
ROLE_ARN=$(aws iam get-role --role-name NeuralChatLambdaRole \
  --query 'Role.Arn' --output text)
echo "Role ARN: $ROLE_ARN"
```

---

## Step 4 — Deploy Lambda Function

### 4a. Package the function

```bash
cd lambda/
zip function.zip lambda_function.py
```

### 4b. Create the Lambda function

```bash
# Set these variables from your earlier steps
AMI_ID="ami-xxxxxxxxxxxxxxxxx"          # from Step 1d
SG_ID="sg-xxxxxxxxxxxxxxxxx"            # from Step 2
SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=defaultForAz,Values=true" \
  --query 'Subnets[0].SubnetId' --output text)

ROLE_ARN="arn:aws:iam::ACCOUNT_ID:role/NeuralChatLambdaRole"  # from Step 3

aws lambda create-function \
  --function-name neuralchat-inference \
  --runtime python3.12 \
  --role $ROLE_ARN \
  --handler lambda_function.lambda_handler \
  --zip-file fileb://function.zip \
  --timeout 900 \
  --memory-size 256 \
  --environment "Variables={
    AMI_ID=$AMI_ID,
    SECURITY_GROUP_ID=$SG_ID,
    SUBNET_ID=$SUBNET_ID,
    AWS_REGION_NAME=us-east-1,
    INFERENCE_PORT=8000
  }" \
  --region us-east-1
```

### 4c. Create a Function URL

```bash
# Add function URL with CORS
aws lambda create-function-url-config \
  --function-name neuralchat-inference \
  --auth-type NONE \
  --cors '{
    "AllowOrigins": ["*"],
    "AllowMethods": ["POST", "OPTIONS"],
    "AllowHeaders": ["Content-Type"],
    "MaxAge": 86400
  }' \
  --region us-east-1

# Allow public access
aws lambda add-permission \
  --function-name neuralchat-inference \
  --action lambda:InvokeFunctionUrl \
  --principal '*' \
  --function-url-auth-type NONE \
  --statement-id allow-public-url \
  --region us-east-1

# Get your Function URL
aws lambda get-function-url-config \
  --function-name neuralchat-inference \
  --query 'FunctionUrl' --output text \
  --region us-east-1
# → https://xxxxxxxxxxxxxxxx.lambda-url.us-east-1.on.aws/
```

**Copy this URL — you'll paste it into the frontend.**

### 4d. Update Lambda (after code changes)

```bash
cd lambda/
zip function.zip lambda_function.py
aws lambda update-function-code \
  --function-name neuralchat-inference \
  --zip-file fileb://function.zip \
  --region us-east-1
```

---

## Step 5 — Configure the Frontend

1. Open `index.html` in a browser locally: `open index.html`
2. Click the **⚙ Settings** icon (top right)
3. Paste your Lambda Function URL
4. Click **Save Settings**
5. Select a model from the sidebar dropdown
6. Type a message and click Send

The settings (Lambda URL, theme, selected model) are saved in `localStorage` — they persist across page refreshes.

---

## Step 6 — Deploy Frontend Online

### Option A: GitHub Pages (Free, automatic)

```bash
cd /path/to/ai-inference-poc

# Initialize git and push
git init
git add .
git commit -m "Initial commit: NeuralChat AI Inference POC"

# Create GitHub repo and push (requires gh CLI)
gh repo create ai-inference-poc \
  --public \
  --source=. \
  --remote=origin \
  --push

# Enable GitHub Pages
gh api repos/:owner/ai-inference-poc/pages \
  -X POST \
  -f source[branch]=main \
  -f source[path]=/

echo "Your site will be live at: https://<YOUR_GITHUB_USERNAME>.github.io/ai-inference-poc"
```

GitHub Actions (`.github/workflows/deploy.yml`) will auto-deploy on every push.

### Option B: Netlify (Free, instant CDN)

```bash
# Install Netlify CLI
npm install -g netlify-cli

# Deploy (one command)
netlify deploy --prod --dir .

# Or connect to GitHub for auto-deploys:
# netlify.com → New site from Git → select your repo → Deploy
```

### Option C: Run locally

```bash
# Python simple server
python3 -m http.server 3000
# Open: http://localhost:3000
```

---

## Step 7 — End-to-End Test

### Test Lambda directly

```bash
LAMBDA_URL="https://xxxxxxxx.lambda-url.us-east-1.on.aws/"

# Simple text test
curl -X POST $LAMBDA_URL \
  -H 'Content-Type: application/json' \
  -d '{"model":"llama3.2:1b","prompt":"What is 2+2? Answer in one word."}' \
  | python3 -m json.tool

# Expected response shape:
# {
#   "response": "Four",
#   "model": "llama3.2:1b",
#   "instance_id": "i-xxxxxxxxxxxxxxxxx",
#   "timing": {
#     "total_seconds": 245.3,
#     "ec2_startup_seconds": 180.2,
#     "server_ready_seconds": 45.1,
#     "inference_seconds": 20.0
#   }
# }
```

### Test with image (vision model)

```bash
# Encode image to base64
IMAGE_B64=$(base64 -i /path/to/image.jpg | tr -d '\n')

curl -X POST $LAMBDA_URL \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"llava:7b\",\"prompt\":\"What is in this image?\",\"image\":\"$IMAGE_B64\"}" \
  | python3 -m json.tool
```

### Full UI test checklist

- [ ] Open frontend URL
- [ ] Click Settings → paste Lambda URL → Save
- [ ] Select "Llama 3.2 1B" (fastest for first test)
- [ ] Type "Hello, tell me a fun fact" → Send
- [ ] Observe the loader showing EC2 startup → server ready → inference steps
- [ ] Response appears with timing card showing breakdown
- [ ] Test code generation: "Write Python bubble sort"
- [ ] Test markdown: "Show me a markdown table of planets"
- [ ] Upload an image and ask "llava:7b" to describe it
- [ ] Start new conversation → verify history saved in sidebar

---

## Troubleshooting

### Lambda times out

- Lambda timeout defaults to 3s — ensure you set it to **900s** (15 min)
  ```bash
  aws lambda update-function-configuration \
    --function-name neuralchat-inference \
    --timeout 900
  ```

### EC2 "no public IP"

- Ensure the subnet is a **public subnet** (has an internet gateway route)
- Ensure `AssociatePublicIpAddress` is enabled in the Lambda code
- Check the `SUBNET_ID` env var points to a public subnet

### Server health check never passes

```bash
# SSH into the EC2 that Lambda launched (check CloudWatch Logs for the instance ID)
# Check service status
sudo systemctl status neuralchat
sudo journalctl -u neuralchat -n 50

# Check Ollama
sudo systemctl status ollama
ollama list
```

### CORS errors in browser

Make sure the Lambda Function URL CORS config allows `*` origins:
```bash
aws lambda update-function-url-config \
  --function-name neuralchat-inference \
  --cors '{"AllowOrigins":["*"],"AllowMethods":["POST","OPTIONS"],"AllowHeaders":["Content-Type"]}'
```

### Model not found on EC2

The model wasn't pre-pulled in the AMI. SSH in, run `ollama pull <model>`, then recreate the AMI.

---

## Cost Estimate

| Component | Details | Est. Cost |
|-----------|---------|-----------|
| Lambda | 15 min max per request, 256 MB | ~$0.004 / request |
| EC2 t3.large | ~3 min for tiny models | ~$0.003 / request |
| EC2 t3.2xlarge | ~6 min for 7B models | ~$0.025 / request |
| EC2 r5.2xlarge | ~15 min for 70B models | ~$0.12 / request |
| Data transfer | < 100 KB response typically | < $0.001 / request |

**Most requests cost under $0.05 total** for small/medium models.

---

## Project Structure

```
ai-inference-poc/
├── index.html              # Main frontend page
├── css/
│   └── style.css           # Dark/light theme styles
├── js/
│   └── app.js              # All frontend logic
├── lambda/
│   ├── lambda_function.py  # Lambda handler (EC2 lifecycle + inference)
│   └── requirements.txt    # Lambda deps (stdlib only)
├── ec2-setup/
│   ├── setup_ami.sh        # One-time AMI setup script
│   ├── inference_server.py # HTTP server on EC2 (Ollama bridge)
│   └── inference_server.service  # Systemd unit file
├── .github/workflows/
│   └── deploy.yml          # Auto-deploy to GitHub Pages
├── netlify.toml            # Netlify deployment config
└── README.md               # This file
```

---

## Extending This POC

- **Streaming**: Replace `/api/generate` with Ollama's streaming API and use Lambda response streaming
- **Persistent EC2**: Keep an EC2 running between requests for faster response (add Start/Stop logic instead of Run/Terminate)
- **GPU instances**: Change instance types to `g4dn.*` or `p3.*` for GPU inference
- **Authentication**: Add Lambda Function URL auth type `AWS_IAM` for production use
- **Custom models**: Add `GGUF` files to the AMI via `ollama create`
