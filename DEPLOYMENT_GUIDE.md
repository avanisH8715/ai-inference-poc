# NeuralChat — Deployment Guide

A step-by-step walkthrough covering:

1. **[Part A](#part-a--lambda-code--config)** — Lambda code and required config
2. **[Part B](#part-b--creating-the-ami)** — Creating the EC2 AMI
3. **[Part C](#part-c--making-a-request--tracking-total-time)** — Making requests and tracking total request-to-response time

> **TL;DR:** Run `./deploy.sh` from the repo root — it automates all of Parts A and B.
> Then read Part C to understand how timing is measured end-to-end.

---

## Part A — Lambda: Code & Config

### A1. Lambda code

The handler is [lambda/lambda_function.py](lambda/lambda_function.py) — it's already complete. What it does on each request:

| Phase | Code location | What happens | Timer |
|-------|---------------|--------------|-------|
| 1. Parse | [lambda_function.py:86-100](lambda/lambda_function.py#L86-L100) | Read `{model, prompt, image?}` from body | — |
| 2. Launch EC2 | [lambda_function.py:104-140](lambda/lambda_function.py#L104-L140) | `run_instances` from AMI, pick instance type from `MODEL_INSTANCE_MAP` | `ec2_start` |
| 3. Wait running | [lambda_function.py:142-149](lambda/lambda_function.py#L142-L149) | `waiter.wait('instance_running')` → get public IP | `ec2_running_time` |
| 4. Wait health | [lambda_function.py:161-164](lambda/lambda_function.py#L161-L164) | Poll `GET /health` every 8s until 200 | `server_ready_time` |
| 5. Run inference | [lambda_function.py:166-170](lambda/lambda_function.py#L166-L170) | `POST /inference` → Ollama → response | `inference_time` |
| 6. Terminate | [lambda_function.py:192-199](lambda/lambda_function.py#L192-L199) | `finally` block — `terminate_instances` always runs | — |

**Response shape returned to the browser:**

```json
{
  "response":    "<LLM output>",
  "model":       "llama3.2:3b",
  "instance_id": "i-0abc...",
  "timing": {
    "total_seconds":        245.30,
    "ec2_startup_seconds":  180.20,
    "server_ready_seconds":  45.10,
    "inference_seconds":     20.00
  }
}
```

### A2. Required Lambda config

These are **not defaults** — you must set them, either via `deploy.sh` or manually:

| Setting | Default | **Required value** | Why |
|---------|---------|--------------------|-----|
| `--timeout` | 3s | **900s (15 min)** | EC2 cold start + inference can take 3–5 min |
| `--memory-size` | 128 MB | **256 MB** | Lambda is light — only boto3 + HTTP polling |
| `--runtime` | — | **python3.12** | `str \| None` type hints in the code |
| `--handler` | — | **`lambda_function.lambda_handler`** | Entry point |

### A3. Required environment variables

Lambda reads these at runtime ([lambda_function.py:29-35](lambda/lambda_function.py#L29-L35)):

```
AMI_ID              = ami-xxxxxxxxxxxxxxxxx    (from Part B)
SECURITY_GROUP_ID   = sg-xxxxxxxxxxxxxxxxx    (allows TCP 8000)
SUBNET_ID           = subnet-xxxxxxxxxxxxxxxxx (public subnet)
AWS_REGION_NAME     = us-east-1
INFERENCE_PORT      = 8000
```

### A4. Required IAM permissions

The Lambda execution role needs these EC2 actions (plus `AWSLambdaBasicExecutionRole` for CloudWatch logs):

- `ec2:RunInstances`
- `ec2:DescribeInstances`
- `ec2:TerminateInstances`
- `ec2:CreateTags`
- `ec2:DescribeSubnets`
- `ec2:DescribeSecurityGroups`

See [README.md — Step 3](README.md#step-3--create-iam-role-for-lambda) for the exact inline policy JSON.

### A5. Function URL config

```
--auth-type NONE
--cors AllowOrigins=["*"], AllowMethods=["POST","OPTIONS"], AllowHeaders=["Content-Type"]
```

Plus a `lambda:InvokeFunctionUrl` permission with `principal=*` so the browser can call it without IAM signing.

---

## Part B — Creating the AMI

Two options. Pick one.

### Option 1 — Automated (recommended)

```bash
./deploy.sh
```

Handles everything in Part B *and* Part A in a single run. Skip to Part C when it finishes.

### Option 2 — Manual, step-by-step

```bash
# 1. Find latest Ubuntu 22.04 AMI
UBUNTU_AMI=$(aws ec2 describe-images \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-*" \
            "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text --region us-east-1)

# 2. Create SG allowing port 8000 (needed so you can curl /health during build)
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].VpcId' --output text)

SG_ID=$(aws ec2 create-security-group \
  --group-name neuralchat-inference-sg \
  --description "Allow TCP 8000" \
  --vpc-id $VPC_ID --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID --protocol tcp --port 8000 --cidr 0.0.0.0/0

# Also allow SSH for manual setup
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0

# 3. Launch a builder instance (t3.2xlarge, 60 GB disk)
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $UBUNTU_AMI \
  --instance-type t3.2xlarge \
  --key-name YOUR_KEYPAIR \
  --security-group-ids $SG_ID \
  --associate-public-ip-address \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":60,"VolumeType":"gp3"}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=neuralchat-ami-builder}]' \
  --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-running --instance-ids $INSTANCE_ID

PUBLIC_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "EC2 IP: $PUBLIC_IP"

# 4. Copy setup files and SSH in
scp -i ~/.ssh/YOUR_KEY.pem \
  ec2-setup/setup_ami.sh \
  ec2-setup/inference_server.py \
  ubuntu@$PUBLIC_IP:~/

ssh -i ~/.ssh/YOUR_KEY.pem ubuntu@$PUBLIC_IP

# Inside EC2 — runs Ollama install, model pulls, systemd setup (10–20 min)
sudo chmod +x setup_ami.sh
sudo ./setup_ami.sh

# 5. Verify from inside EC2
curl http://localhost:8000/health
# → {"status":"ok"}

exit

# 6. Verify from your laptop — this is what Lambda will do
curl http://$PUBLIC_IP:8000/health
# → {"status":"ok"}

# 7. Snapshot the EC2 into an AMI
AMI_ID=$(aws ec2 create-image \
  --instance-id $INSTANCE_ID \
  --name neuralchat-inference-v1 \
  --no-reboot \
  --query 'ImageId' --output text)

# 8. Wait for AMI to become available (5–10 min)
aws ec2 wait image-available --image-ids $AMI_ID
echo "AMI ready: $AMI_ID"

# 9. Terminate the builder
aws ec2 terminate-instances --instance-ids $INSTANCE_ID

# 10. Save the AMI_ID into Lambda env vars
SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=defaultForAz,Values=true" \
  --query 'Subnets[0].SubnetId' --output text)

aws lambda update-function-configuration \
  --function-name neuralchat-inference \
  --environment "Variables={AMI_ID=$AMI_ID,SECURITY_GROUP_ID=$SG_ID,SUBNET_ID=$SUBNET_ID,AWS_REGION_NAME=us-east-1,INFERENCE_PORT=8000}"
```

---

## Part C — Making a request & tracking total time

### C1. The simplest end-to-end test (curl with `time`)

```bash
LAMBDA_URL="https://xxxxxxxx.lambda-url.us-east-1.on.aws/"

time curl -X POST "$LAMBDA_URL" \
  -H 'Content-Type: application/json' \
  -d '{"model":"llama3.2:1b","prompt":"What is 2+2?"}' \
  | python3 -m json.tool
```

You get **two timings**:

- **`time`** (wall-clock from your laptop): ~3–4 min for small models
- **`timing` in the response body** (measured inside Lambda): the breakdown

Example output:

```json
{
  "response": "4",
  "model": "llama3.2:1b",
  "instance_id": "i-0abc...",
  "timing": {
    "total_seconds":       210.50,
    "ec2_startup_seconds": 155.20,
    "server_ready_seconds": 42.10,
    "inference_seconds":    13.20
  }
}
```

### C2. How total time is measured

Inside [lambda_function.py:74-186](lambda/lambda_function.py#L74-L186):

```
request_start = time.time()                                     ← START (line 81)
│
├─ Step 1: ec2_start        = time.time()                            (line 105)
│     run_instances + wait for running
│     ec2_running_time = time.time() - ec2_start                     (line 148)
│
├─ Step 2: server_start     = time.time()                            (line 161)
│     poll /health until 200
│     server_ready_time = time.time() - server_start                 (line 163)
│
├─ Step 3: inference_start  = time.time()                            (line 167)
│     POST /inference to EC2
│     inference_time = time.time() - inference_start                 (line 169)
│
└─ total_time = time.time() - request_start                          (line 172)
```

All four numbers are returned in the JSON `timing` object.

### C3. Tracking from the browser (what the UI does)

The frontend ([js/app.js](js/app.js)) also measures its own wall-clock:

```javascript
const t0 = performance.now();
const resp = await fetch(LAMBDA_URL, { method: 'POST', body: ... });
const data = await resp.json();
const browserTotal = (performance.now() - t0) / 1000;
```

So you'll see **three** timing layers in the UI:

| Source | Measures | Includes |
|--------|----------|----------|
| Browser `performance.now()` | Network + Lambda + EC2 + inference + response | Everything |
| Lambda `timing.total_seconds` | EC2 lifecycle + inference | No browser→Lambda latency |
| `timing.inference_seconds` | Just the Ollama `/api/generate` call | Pure model time |

The UI renders all of them in the timing card after each response.

### C4. Typical timings to expect

| Model | Instance | Total (cold) | EC2 boot | Server ready | Inference |
|-------|----------|-------------:|---------:|-------------:|----------:|
| `llama3.2:1b` | t3.large | ~3 min | 2:30 | 0:15 | 0:10 |
| `llama3.2:3b` | t3.xlarge | ~4 min | 2:30 | 0:40 | 0:30 |
| `mistral:7b` | t3.2xlarge | ~6 min | 2:30 | 1:30 | 1:30 |
| `llama3.1:70b` | r5.2xlarge | ~15 min | 3:00 | 3:00 | 9:00 |

**Every request cold-starts a fresh EC2** (instance is terminated after each call). To eliminate the 2–3 min EC2 boot, switch to the "persistent EC2" pattern — see [Extending This POC](README.md#extending-this-poc).

### C5. Quick debugging checklist

| Symptom | Fix |
|---------|-----|
| Lambda times out at 3s | You forgot `--timeout 900` |
| "no public IP" error | `SUBNET_ID` points to a private subnet |
| Health check never passes | SSH into the EC2 Lambda launched → `sudo journalctl -u neuralchat -n 50` |
| CORS error in browser | Re-run `update-function-url-config` with `AllowOrigins=["*"]` |
| Cost unexpectedly high | Check CloudWatch logs for "Terminating instance" — confirms `finally` ran |

---

## Summary

1. **Lambda code** is already at [lambda/lambda_function.py](lambda/lambda_function.py) — no edits needed. Just set `timeout=900s`, `memory=256MB`, and the 5 env vars.
2. **Create the AMI** via `./deploy.sh` (automated, ~25 min) or Part B Option 2 (manual).
3. **Request + timing**: `curl` the Function URL, read `timing.total_seconds` for Lambda-side total, wrap with `time` for true wall-clock. The UI shows both side-by-side.
