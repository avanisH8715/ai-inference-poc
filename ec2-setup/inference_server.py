"""
NeuralChat Inference Server
Runs on EC2 inside the AMI. Bridges Lambda HTTP requests to Ollama's local API.
Starts automatically via systemd on boot.

Endpoints:
  GET  /health      — Returns {"status":"ok"} when Ollama is ready
  POST /inference   — Accepts {model, prompt, image?} → returns {response}
"""

import json
import time
import base64
import logging
import urllib.request
import urllib.error
from http.server import HTTPServer, BaseHTTPRequestHandler

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger(__name__)

OLLAMA_BASE = "http://127.0.0.1:11434"
PORT = 8000


class InferenceHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        logger.info(f"{self.address_string()} - {format % args}")

    def send_json(self, status: int, body: dict):
        data = json.dumps(body).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', len(data))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def do_GET(self):
        if self.path == '/health':
            if _ollama_ready():
                self.send_json(200, {'status': 'ok'})
            else:
                self.send_json(503, {'status': 'starting', 'message': 'Ollama not ready yet'})
        else:
            self.send_json(404, {'error': 'Not found'})

    def do_POST(self):
        if self.path != '/inference':
            self.send_json(404, {'error': 'Not found'})
            return

        try:
            length = int(self.headers.get('Content-Length', 0))
            body = json.loads(self.rfile.read(length).decode('utf-8'))
        except Exception as e:
            self.send_json(400, {'error': f'Invalid JSON: {e}'})
            return

        model   = body.get('model', 'llama3.2:3b')
        prompt  = body.get('prompt', '')
        image_b64 = body.get('image')  # base64 string without data: prefix

        if not prompt and not image_b64:
            self.send_json(400, {'error': 'prompt or image required'})
            return

        try:
            response_text = _run_ollama(model, prompt, image_b64)
            self.send_json(200, {'response': response_text})
        except Exception as e:
            logger.exception(f"Inference error: {e}")
            self.send_json(500, {'error': str(e)})


def _ollama_ready() -> bool:
    """Return True if Ollama's API is responding."""
    try:
        req = urllib.request.Request(f"{OLLAMA_BASE}/api/tags", method='GET')
        with urllib.request.urlopen(req, timeout=3) as resp:
            return resp.status == 200
    except Exception:
        return False


def _run_ollama(model: str, prompt: str, image_b64: str | None) -> str:
    """Call Ollama's /api/generate endpoint and return the full response text."""
    payload: dict = {
        'model':  model,
        'prompt': prompt,
        'stream': False,
    }
    if image_b64:
        # Ollama expects a list of base64-encoded image strings
        payload['images'] = [image_b64]

    data = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(
        f"{OLLAMA_BASE}/api/generate",
        data=data,
        headers={'Content-Type': 'application/json'},
        method='POST',
    )

    logger.info(f"Sending to Ollama: model={model}, prompt_len={len(prompt)}, has_image={bool(image_b64)}")
    start = time.time()

    with urllib.request.urlopen(req, timeout=600) as resp:
        result = json.loads(resp.read().decode('utf-8'))

    elapsed = time.time() - start
    logger.info(f"Ollama responded in {elapsed:.2f}s")
    return result.get('response', '')


def _wait_for_ollama(max_wait: int = 120):
    """Block until Ollama is responsive (called once at startup)."""
    logger.info("Waiting for Ollama to start...")
    deadline = time.time() + max_wait
    while time.time() < deadline:
        if _ollama_ready():
            logger.info("Ollama is ready.")
            return
        time.sleep(3)
    logger.warning("Ollama not ready within timeout — /health will reflect this.")


if __name__ == '__main__':
    _wait_for_ollama()
    server = HTTPServer(('0.0.0.0', PORT), InferenceHandler)
    logger.info(f"Inference server running on port {PORT}")
    server.serve_forever()
