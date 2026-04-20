"""
NeuralChat AI Inference Lambda
Spins up an EC2 instance from a pre-built AMI, runs AI inference via Ollama,
returns the response with detailed timing metrics, then terminates the instance.

Environment variables (set in Lambda console):
  AMI_ID             - Your custom AMI ID (ami-xxxxxxxxxxxxxxxxx)
  SECURITY_GROUP_ID  - Security group allowing inbound TCP 8000
  SUBNET_ID          - Public subnet ID (EC2 needs internet access)
  KEY_NAME           - (Optional) EC2 key pair for SSH debugging
  IAM_INSTANCE_PROFILE - (Optional) Instance profile ARN if needed
  AWS_REGION_NAME    - AWS region (default: us-east-1)
  INFERENCE_PORT     - Port for inference server (default: 8000)
"""

import json
import os
import time
import logging
import boto3
import urllib.request
import urllib.error
import urllib.parse

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ---- Configuration ----
REGION           = os.environ.get('AWS_REGION_NAME', 'us-east-1')
AMI_ID           = os.environ.get('AMI_ID', 'ami-REPLACE-WITH-YOUR-AMI-ID')
SECURITY_GROUP_ID = os.environ.get('SECURITY_GROUP_ID', 'sg-REPLACE-WITH-YOUR-SG-ID')
SUBNET_ID        = os.environ.get('SUBNET_ID', 'subnet-REPLACE-WITH-YOUR-SUBNET-ID')
KEY_NAME         = os.environ.get('KEY_NAME', '')
IAM_INSTANCE_PROFILE = os.environ.get('IAM_INSTANCE_PROFILE', '')
INFERENCE_PORT   = int(os.environ.get('INFERENCE_PORT', '8000'))

# Max seconds to wait for EC2 server to be responsive after "running" state
SERVER_READY_TIMEOUT = 300
SERVER_POLL_INTERVAL = 8

# Instance type per model (EC2 CPU-based for simplicity; swap for GPU types as needed)
MODEL_INSTANCE_MAP = {
    'llama3.2:1b':   't3.large',
    'phi3:mini':     't3.large',
    'gemma2:2b':     't3.large',
    'llama3.2:3b':   't3.xlarge',
    'mistral:7b':    't3.2xlarge',
    'llama3.1:8b':   't3.2xlarge',
    'llava:7b':      't3.2xlarge',
    'llama3.1:70b':  'r5.2xlarge',
    'mixtral:8x7b':  'r5.xlarge',
}
DEFAULT_INSTANCE_TYPE = 't3.xlarge'


# ---- CORS helpers ----
CORS_HEADERS = {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
}


def ok(body: dict) -> dict:
    return {'statusCode': 200, 'headers': CORS_HEADERS, 'body': json.dumps(body)}


def error(status: int, message: str) -> dict:
    return {'statusCode': status, 'headers': CORS_HEADERS, 'body': json.dumps({'error': message})}


# ---- Lambda entry point ----
def lambda_handler(event, context):
    # Handle CORS preflight
    method = (event.get('requestContext', {}).get('http', {}).get('method', '') or
              event.get('httpMethod', ''))
    if method.upper() == 'OPTIONS':
        return {'statusCode': 200, 'headers': CORS_HEADERS, 'body': ''}

    request_start = time.time()
    instance_id = None
    ec2_client = boto3.client('ec2', region_name=REGION)

    try:
        # ---- Parse request body ----
        raw_body = event.get('body', '{}') or '{}'
        if isinstance(raw_body, str):
            body = json.loads(raw_body)
        else:
            body = raw_body

        model      = body.get('model', 'llama3.2:3b').strip()
        prompt     = body.get('prompt', '').strip()
        image_b64  = body.get('image')   # base64 string, no data: prefix

        if not prompt and not image_b64:
            return error(400, 'Request must include a prompt or image')

        logger.info(f"Request: model={model}, prompt_len={len(prompt)}, has_image={bool(image_b64)}")

        instance_type = MODEL_INSTANCE_MAP.get(model, DEFAULT_INSTANCE_TYPE)

        # ---- Step 1: Launch EC2 ----
        ec2_start = time.time()
        logger.info(f"Launching EC2 {instance_type} from AMI {AMI_ID}")

        run_kwargs = dict(
            ImageId=AMI_ID,
            InstanceType=instance_type,
            MinCount=1,
            MaxCount=1,
            TagSpecifications=[{
                'ResourceType': 'instance',
                'Tags': [
                    {'Key': 'Name',    'Value': 'neuralchat-inference'},
                    {'Key': 'Purpose', 'Value': 'ai-inference-poc'},
                ]
            }],
        )

        # Associate with public subnet and SG if configured
        network_iface = {
            'DeviceIndex': 0,
            'AssociatePublicIpAddress': True,
        }
        if SECURITY_GROUP_ID and not SECURITY_GROUP_ID.startswith('sg-REPLACE'):
            network_iface['Groups'] = [SECURITY_GROUP_ID]
        if SUBNET_ID and not SUBNET_ID.startswith('subnet-REPLACE'):
            network_iface['SubnetId'] = SUBNET_ID
        run_kwargs['NetworkInterfaces'] = [network_iface]

        if KEY_NAME:
            run_kwargs['KeyName'] = KEY_NAME
        if IAM_INSTANCE_PROFILE:
            run_kwargs['IamInstanceProfile'] = {'Arn': IAM_INSTANCE_PROFILE}

        resp = ec2_client.run_instances(**run_kwargs)
        instance_id = resp['Instances'][0]['InstanceId']
        logger.info(f"Instance launched: {instance_id}")

        # ---- Step 2: Wait for "running" ----
        waiter = ec2_client.get_waiter('instance_running')
        waiter.wait(
            InstanceIds=[instance_id],
            WaiterConfig={'Delay': 5, 'MaxAttempts': 40}
        )
        ec2_running_time = time.time() - ec2_start
        logger.info(f"EC2 running after {ec2_running_time:.1f}s")

        # ---- Get public IP ----
        desc = ec2_client.describe_instances(InstanceIds=[instance_id])
        public_ip = desc['Reservations'][0]['Instances'][0].get('PublicIpAddress')
        if not public_ip:
            raise RuntimeError("EC2 instance has no public IP. Check subnet/SG config.")

        server_base = f"http://{public_ip}:{INFERENCE_PORT}"
        logger.info(f"EC2 public IP: {public_ip}, server: {server_base}")

        # ---- Step 3: Wait for inference server to be ready ----
        server_start = time.time()
        _wait_for_server(server_base)
        server_ready_time = time.time() - server_start
        logger.info(f"Server ready after {server_ready_time:.1f}s")

        # ---- Step 4: Run inference ----
        inference_start = time.time()
        result = _run_inference(server_base, model, prompt, image_b64)
        inference_time = time.time() - inference_start
        logger.info(f"Inference done in {inference_time:.1f}s")

        total_time = time.time() - request_start

        timing = {
            'total_seconds':         round(total_time, 2),
            'ec2_startup_seconds':   round(ec2_running_time, 2),
            'server_ready_seconds':  round(server_ready_time, 2),
            'inference_seconds':     round(inference_time, 2),
        }

        return ok({
            'response':    result,
            'model':       model,
            'instance_id': instance_id,
            'timing':      timing,
        })

    except Exception as exc:
        logger.exception(f"Inference pipeline failed: {exc}")
        return error(500, str(exc))

    finally:
        # Always terminate the instance to avoid cost leakage
        if instance_id:
            try:
                ec2_client.terminate_instances(InstanceIds=[instance_id])
                logger.info(f"Terminating instance {instance_id}")
            except Exception as term_err:
                logger.warning(f"Could not terminate {instance_id}: {term_err}")


# ---- Helpers ----

def _wait_for_server(base_url: str):
    """Poll /health until 200 or timeout."""
    health_url = f"{base_url}/health"
    deadline = time.time() + SERVER_READY_TIMEOUT
    attempt = 0
    while time.time() < deadline:
        attempt += 1
        try:
            req = urllib.request.Request(health_url, method='GET')
            with urllib.request.urlopen(req, timeout=5) as resp:
                if resp.status == 200:
                    logger.info(f"Health check passed on attempt {attempt}")
                    return
        except Exception as e:
            logger.debug(f"Health attempt {attempt}: {e}")
        time.sleep(SERVER_POLL_INTERVAL)
    raise TimeoutError(
        f"Inference server not ready after {SERVER_READY_TIMEOUT}s "
        f"({attempt} health checks). Check EC2 logs."
    )


def _run_inference(base_url: str, model: str, prompt: str, image_b64: str | None) -> str:
    """POST to /inference on the EC2 server and return the response text."""
    payload = {
        'model':  model,
        'prompt': prompt,
    }
    if image_b64:
        payload['image'] = image_b64

    data = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(
        f"{base_url}/inference",
        data=data,
        headers={'Content-Type': 'application/json'},
        method='POST',
    )
    with urllib.request.urlopen(req, timeout=600) as resp:
        result = json.loads(resp.read().decode('utf-8'))
    return result.get('response', '')
