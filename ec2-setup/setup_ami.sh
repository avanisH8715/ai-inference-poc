#!/usr/bin/env bash
# =============================================================================
# NeuralChat — EC2 AMI Setup Script
# Run this ONCE on a fresh EC2 instance, then create an AMI from it.
#
# Tested on: Ubuntu 22.04 LTS (ami-0c7217cdde317cfec in us-east-1)
# Recommended instance for setup: t3.2xlarge (adjust MODELS_TO_PULL below)
#
# Usage:
#   chmod +x setup_ami.sh
#   sudo ./setup_ami.sh
# =============================================================================

set -euo pipefail
LOG="/var/log/neuralchat-setup.log"
exec > >(tee -a "$LOG") 2>&1

echo "============================================="
echo " NeuralChat AMI Setup — $(date)"
echo "============================================="

# ---- Which models to pre-pull into the AMI ----
# Add/remove models based on your use case and storage budget.
# Each model is stored in /usr/share/ollama/.ollama/models
MODELS_TO_PULL=(
  "llama3.2:1b"      # 0.8 GB — tiny, fast
  "phi3:mini"        # 2.3 GB — Microsoft, efficient
  "llama3.2:3b"      # 2.0 GB — balanced (default)
  "gemma2:2b"        # 1.6 GB — Google
  # Uncomment for medium/large models (need bigger disk + instance):
  # "mistral:7b"     # 4.1 GB
  # "llama3.1:8b"    # 4.9 GB
  # "llava:7b"       # 4.5 GB — multimodal
)

# ---- 1. System Updates ----
echo ""
echo "[1/7] Updating system packages..."
apt-get update -y
apt-get upgrade -y
apt-get install -y \
  curl \
  wget \
  python3 \
  python3-pip \
  python3-venv \
  htop \
  unzip \
  jq \
  net-tools

# ---- 2. Install Ollama ----
echo ""
echo "[2/7] Installing Ollama..."
if ! command -v ollama &>/dev/null; then
  curl -fsSL https://ollama.com/install.sh | sh
  echo "Ollama installed: $(ollama --version)"
else
  echo "Ollama already installed, skipping."
fi

# Ensure ollama service is running for model downloads
systemctl enable ollama
systemctl start ollama

# Wait for Ollama API to be ready
echo "Waiting for Ollama API..."
for i in $(seq 1 30); do
  if curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
    echo "Ollama API ready."
    break
  fi
  sleep 3
done

# ---- 3. Pull AI Models ----
echo ""
echo "[3/7] Pulling AI models (this may take a while)..."
for model in "${MODELS_TO_PULL[@]}"; do
  echo ""
  echo "  Pulling: $model"
  ollama pull "$model" || echo "  WARNING: Failed to pull $model, skipping."
done

echo ""
echo "Models installed:"
ollama list

# ---- 4. Set Up Python Virtual Environment ----
echo ""
echo "[4/7] Setting up Python environment..."
python3 -m venv /opt/neuralchat-venv
/opt/neuralchat-venv/bin/pip install --upgrade pip

# No external deps needed — inference_server.py uses only stdlib
echo "Python venv ready at /opt/neuralchat-venv"

# ---- 5. Install Inference Server ----
echo ""
echo "[5/7] Installing inference server..."
mkdir -p /opt/neuralchat

# Copy inference_server.py (assumes it's in the same directory as this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/inference_server.py" ]]; then
  cp "$SCRIPT_DIR/inference_server.py" /opt/neuralchat/inference_server.py
else
  echo "  inference_server.py not found in $SCRIPT_DIR, downloading from repo..."
  # Fallback: create a minimal version inline
  cat > /opt/neuralchat/inference_server.py << 'PYEOF'
import json, time, logging, urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler
logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')
logger = logging.getLogger(__name__)
OLLAMA_BASE = "http://127.0.0.1:11434"
PORT = 8000
class InferenceHandler(BaseHTTPRequestHandler):
    def log_message(self, f, *a): logger.info(f"{self.address_string()} - {f % a}")
    def send_json(self, s, b):
        d = json.dumps(b).encode()
        self.send_response(s); self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',len(d)); self.send_header('Access-Control-Allow-Origin','*')
        self.end_headers(); self.wfile.write(d)
    def do_OPTIONS(self):
        self.send_response(200); self.send_header('Access-Control-Allow-Origin','*')
        self.send_header('Access-Control-Allow-Methods','GET,POST,OPTIONS')
        self.send_header('Access-Control-Allow-Headers','Content-Type'); self.end_headers()
    def do_GET(self):
        if self.path=='/health':
            try:
                urllib.request.urlopen(f"{OLLAMA_BASE}/api/tags",timeout=3)
                self.send_json(200,{'status':'ok'})
            except: self.send_json(503,{'status':'starting'})
        else: self.send_json(404,{'error':'not found'})
    def do_POST(self):
        if self.path!='/inference': self.send_json(404,{'error':'not found'}); return
        body=json.loads(self.rfile.read(int(self.headers.get('Content-Length',0))).decode())
        model=body.get('model','llama3.2:3b'); prompt=body.get('prompt',''); img=body.get('image')
        pl={'model':model,'prompt':prompt,'stream':False}
        if img: pl['images']=[img]
        req=urllib.request.Request(f"{OLLAMA_BASE}/api/generate",json.dumps(pl).encode(),{'Content-Type':'application/json'},'POST')
        with urllib.request.urlopen(req,timeout=600) as r: result=json.loads(r.read())
        self.send_json(200,{'response':result.get('response','')})
if __name__=='__main__':
    for _ in range(40):
        try: urllib.request.urlopen(f"{OLLAMA_BASE}/api/tags",timeout=3); break
        except: time.sleep(3)
    HTTPServer(('0.0.0.0',PORT),InferenceHandler).serve_forever()
PYEOF
fi

chmod +x /opt/neuralchat/inference_server.py
echo "Inference server installed at /opt/neuralchat/inference_server.py"

# ---- 6. Create Systemd Service ----
echo ""
echo "[6/7] Creating systemd service..."

cat > /etc/systemd/system/neuralchat.service << 'EOF'
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
EOF

systemctl daemon-reload
systemctl enable neuralchat
systemctl start neuralchat

echo "Systemd service 'neuralchat' enabled and started."

# ---- 7. Configure Firewall / Verify Port ----
echo ""
echo "[7/7] Verifying setup..."

sleep 5

# Quick sanity check
if curl -sf http://localhost:8000/health | grep -q '"ok"'; then
  echo "✓ Inference server health check PASSED"
else
  echo "⚠ Inference server health check pending (Ollama may still be starting)"
  echo "  Check: sudo journalctl -u neuralchat -f"
fi

if ollama list | grep -q "llama"; then
  echo "✓ Ollama models available"
fi

cat << 'SUMMARY'

=============================================================================
  AMI SETUP COMPLETE
=============================================================================

Next steps:
  1. Test the server:
       curl http://localhost:8000/health
       curl -X POST http://localhost:8000/inference \
         -H 'Content-Type: application/json' \
         -d '{"model":"llama3.2:3b","prompt":"Hello, who are you?"}'

  2. Create an AMI from this instance:
       AWS Console → EC2 → Instances → Select this instance
       → Actions → Image and templates → Create image
       Name: "neuralchat-inference-v1"
       No reboot: checked (optional)

  3. Note the new AMI ID (ami-xxxxxxxxxxxxxxxxx) and add it to
     your Lambda's AMI_ID environment variable.

  4. IMPORTANT — Security Group for EC2:
     Allow inbound TCP port 8000 from Lambda's IP range
     (or 0.0.0.0/0 for testing — tighten for production)

  5. Stop/terminate this setup instance to save costs.

=============================================================================
SUMMARY

echo "Setup complete at $(date)."
