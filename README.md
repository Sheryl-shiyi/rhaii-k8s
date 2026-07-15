# RHAII vLLM Model Serving on Kubernetes

A Helm chart for deploying [Red Hat AI Inference (RHAII)](https://docs.redhat.com/en/documentation/red_hat_ai_inference/3.4) vLLM model serving on any Kubernetes cluster with NVIDIA GPU support.

## Features

- **Three model source modes**: OCI registry (default), HuggingFace Hub, or preloaded PVC
- **Air-gap ready**: Mirror images to your local registry for disconnected environments
- **GPU node scheduling**: Configurable `nodeSelector` and `tolerations` for dedicated GPU nodes
- **OpenAI-compatible API**: Exposes `/v1/chat/completions`, `/v1/completions`, and other standard endpoints

## Quick Start (Existing Kubernetes Cluster)

### Prerequisites

- Kubernetes cluster with NVIDIA GPU nodes (driver + device plugin installed)
- `kubectl` and `helm` v3 installed
- Access to `registry.redhat.io` (Red Hat account required) or a local mirror

### Step 1: Clone and configure

```bash
git clone https://github.com/Sheryl-shiyi/rhaii-k8s.git
cd rhaii-k8s
```

Edit `values.yaml` and update the `YOUR_*` placeholders:

| Placeholder | Description | Example |
|---|---|---|
| `YOUR_STORAGE_CLASS` | Your cluster's StorageClass | `gp2`, `managed-premium`, `local-path` |
| `YOUR_PULL_SECRET` | Existing image pull secret name (if applicable) | `my-registry-pull-secret` |
| `YOUR_NODE_LABEL` | GPU node label for `nodeSelector` | `dedicated: rhai` |
| `YOUR_NODE_TAINT` | GPU node taint for `tolerations` | `dedicated=rhai:NoSchedule` |

### Step 2: Install

```bash
# Create namespace
kubectl create namespace rhai

# Option A: Use an existing image pull secret in your cluster
helm install rhaii . -n rhai \
  --set storage.storageClassName=YOUR_STORAGE_CLASS \
  --set registrySecret.existingSecret=YOUR_PULL_SECRET

# Option B: Provide registry credentials directly
helm install rhaii . -n rhai \
  --set storage.storageClassName=YOUR_STORAGE_CLASS \
  --set registrySecret.dockerconfigjson=$(cat ~/.config/containers/auth.json | base64)
```

### Step 3: Verify

```bash
# Watch pod startup (model download + loading takes several minutes)
kubectl get pods -n rhai -w

# Once pod shows 1/1 Running, test the API
kubectl port-forward -n rhai svc/rhaii-rhaii-vllm 8000:80

curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mistral-small-3.1-24b-instruct",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 100
  }'
```

## Deploying on AWS EKS from Scratch

If you don't have a Kubernetes cluster yet, see the full step-by-step guide:

**[AWS EKS Deployment Guide](examples/aws-eks-guide.md)** -- Covers EKS cluster creation, EBS CSI driver setup, GPU node configuration, and RHAII deployment.

## Model Source Modes

### Alt 1: OCI (default)

Pulls the model as an OCI artifact from a container registry using an ORAS init container. This is the recommended mode for production and air-gapped environments.

```yaml
# values.yaml
model:
  source: oci
  ociImage: registry.redhat.io/rhelai1/mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5
```

For air-gapped clusters with a local registry, mirror the images from a machine with internet access:

```bash
# On a machine with internet access (e.g., jumphost)

# Method 1 (Recommended): Using podman
podman pull registry.redhat.io/rhaii/vllm-cuda-rhel9:3.4.0
podman push registry.redhat.io/rhaii/vllm-cuda-rhel9:3.4.0 \
  local-registry.example.com/rhaii/vllm-cuda-rhel9:3.4.0

podman pull registry.redhat.io/rhelai1/mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5
podman push registry.redhat.io/rhelai1/mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5 \
  local-registry.example.com/rhelai1/mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5

# Method 2: Using skopeo (direct registry-to-registry copy, no local storage needed)
skopeo copy \
  docker://registry.redhat.io/rhaii/vllm-cuda-rhel9:3.4.0 \
  docker://local-registry.example.com/rhaii/vllm-cuda-rhel9:3.4.0

skopeo copy \
  docker://registry.redhat.io/rhelai1/mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5 \
  docker://local-registry.example.com/rhelai1/mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5
```

Then update `values.yaml` to point to your local registry:

```yaml
vllm:
  image: local-registry.example.com/rhaii/vllm-cuda-rhel9
model:
  ociImage: local-registry.example.com/rhelai1/mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5
```

### Alt 2: HuggingFace

Downloads the model directly from HuggingFace Hub at pod startup. Requires internet access from the cluster and a HuggingFace token.

```bash
helm install rhaii . -n rhai \
  --set model.source=huggingface \
  --set huggingface.token=hf_YOUR_TOKEN \
  --set storage.storageClassName=YOUR_STORAGE_CLASS \
  --set registrySecret.existingSecret=YOUR_PULL_SECRET
```

### Alt 3: Preloaded

Assumes model files are already present on the PVC. Use this when you have pre-populated the storage through other means (e.g., `kubectl cp`, NFS mount, or a separate download job).

```bash
helm install rhaii . -n rhai \
  --set model.source=preloaded \
  --set storage.existingClaim=my-model-pvc \
  --set registrySecret.existingSecret=YOUR_PULL_SECRET
```

## Configuration Reference

| Parameter | Default | Description |
|---|---|---|
| `model.source` | `oci` | Model download mode: `oci`, `huggingface`, or `preloaded` |
| `model.ociImage` | `registry.redhat.io/rhelai1/mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5` | OCI model image |
| `model.huggingfaceId` | `RedHatAI/Mistral-Small-3.1-24B-Instruct-2503-quantized.w4a16` | HuggingFace model ID |
| `model.servedName` | `mistral-small-3.1-24b-instruct` | Model name exposed via the API |
| `huggingface.token` | `""` | HuggingFace access token |
| `vllm.image` | `registry.redhat.io/rhaii/vllm-cuda-rhel9` | RHAII vLLM container image |
| `vllm.tag` | `3.4.0` | Image tag |
| `vllm.args.tensorParallelSize` | `1` | Number of GPUs for tensor parallelism |
| `vllm.args.maxModelLen` | `4096` | Maximum sequence length (affects GPU memory usage) |
| `vllm.args.gpuMemoryUtilization` | `0.90` | Fraction of GPU memory to use |
| `vllm.args.enforceEager` | `true` | Disable CUDA graphs to save GPU memory |
| `vllm.extraArgs` | `[]` | Additional vLLM CLI arguments |
| `resources.limits.nvidia.com/gpu` | `1` | Number of GPUs requested |
| `resources.limits.memory` | `16Gi` | Container memory limit |
| `storage.size` | `50Gi` | PVC size for model cache |
| `storage.storageClassName` | `YOUR_STORAGE_CLASS` | Kubernetes StorageClass |
| `storage.existingClaim` | `""` | Use an existing PVC instead of creating one |
| `registrySecret.dockerconfigjson` | `""` | Base64-encoded Docker config for registry auth |
| `registrySecret.existingSecret` | `""` | Name of an existing image pull secret |
| `nodeSelector` | `{dedicated: rhai}` | Node selector for GPU node scheduling |
| `tolerations` | `[{key: dedicated, value: rhai, effect: NoSchedule}]` | Tolerations for GPU node taints |

## Tested Environment

### Hardware

| Component | Specification |
|---|---|
| Platform | Amazon EKS (Kubernetes 1.33) |
| GPU Instance | `g6.xlarge` (1x NVIDIA L4, 24GB VRAM) |
| System Nodes | 2x `m5.xlarge` (4 vCPU, 16GB RAM) |
| Region | us-east-2 (Ohio) |
| GPU Node Label | `dedicated=rhai` |
| GPU Node Taint | `dedicated=rhai:NoSchedule` |

### Software

| Component | Version |
|---|---|
| RHAII vLLM | 3.4.0 (vLLM v0.18.0+rhaiv.7) |
| Model | Mistral-Small-3.1-24B-Instruct-2503-quantized.w4a16 (~14GB) |
| NVIDIA Device Plugin | Auto-installed by eksctl |
| EBS CSI Driver | EKS addon |

### Test Results

Model loading time (from PVC, after initial download): ~2.5 minutes

Inference test:

```bash
kubectl port-forward -n rhai svc/rhaii-rhaii-vllm 8000:80

curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mistral-small-3.1-24b-instruct",
    "messages": [{"role": "user", "content": "Hello! What model are you?"}],
    "max_tokens": 100
  }'
```

Successful response:

```json
{
  "id": "chatcmpl-a318dae55361b09b",
  "object": "chat.completion",
  "model": "mistral-small-3.1-24b-instruct",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Hello! I am Mistral Small 3, a Large Language Model created by Mistral AI. I am designed to understand and generate human language, and I can help answer questions, provide information, and assist with a variety of tasks."
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 184,
    "total_tokens": 246,
    "completion_tokens": 62
  }
}
```

## Troubleshooting

See **[Troubleshooting Guide](examples/troubleshooting.md)** for common issues and solutions, including:
- PVC stuck in Pending
- Tokenizer errors
- Pod restart loops during model loading
- GPU scheduling deadlocks
