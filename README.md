# RHAII vLLM Model Serving on Kubernetes

A Helm chart for deploying [Red Hat AI Inference (RHAII)](https://docs.redhat.com/en/documentation/red_hat_ai_inference/3.4) vLLM model serving on any Kubernetes cluster with NVIDIA GPU support.

## Features

- **Three model source modes**: OCI registry (default), HuggingFace Hub, or preloaded PVC
- **Air-gap ready**: Mirror images to your local registry for disconnected environments
- **GPU node scheduling**: Configurable `nodeSelector` and `tolerations` for dedicated GPU nodes
- **OpenAI-compatible API**: Exposes `/v1/chat/completions`, `/v1/completions`, and other standard endpoints

## Deployment Guide

### Prerequisites

- Kubernetes cluster with NVIDIA GPU nodes (driver + device plugin installed)
- `kubectl` and `helm` v3 installed
- Access to `registry.redhat.io` (Red Hat account required) or a local mirror
- No Kubernetes cluster yet? See **[AWS EKS Deployment Guide](examples/aws-eks-guide.md)**

### Step 1: Clone the repo

```bash
git clone https://github.com/Sheryl-shiyi/rhaii-k8s.git
cd rhaii-k8s
```

### Step 2: Prepare images (choose one mode)

#### Alt 1: OCI (default, recommended for production/air-gap)

The model is pulled as an OCI artifact from a container registry at pod startup. Three images are needed:

| Image | Purpose |
|---|---|
| `registry.redhat.io/rhaii/vllm-cuda-rhel9:3.4.0` | vLLM runtime (main container) |
| `registry.redhat.io/rhelai1/mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5` | Model weights (OCI artifact) |
| `ghcr.io/oras-project/oras:v1.2.0` | ORAS tool (init container, used to pull the model OCI artifact) |

If your cluster can reach these registries directly, no preparation is needed. Skip to Step 3.

For air-gapped clusters, mirror all three images to your local registry from a machine with internet access (e.g., jumphost):

```bash
# Login to Red Hat registry
podman login registry.redhat.io

# Method 1 (Recommended): Using podman
podman pull registry.redhat.io/rhaii/vllm-cuda-rhel9:3.4.0
podman push registry.redhat.io/rhaii/vllm-cuda-rhel9:3.4.0 \
  YOUR_LOCAL_REGISTRY/rhaii/vllm-cuda-rhel9:3.4.0

podman pull registry.redhat.io/rhelai1/mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5
podman push registry.redhat.io/rhelai1/mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5 \
  YOUR_LOCAL_REGISTRY/rhelai1/mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5

podman pull ghcr.io/oras-project/oras:v1.2.0
podman push ghcr.io/oras-project/oras:v1.2.0 \
  YOUR_LOCAL_REGISTRY/oras-project/oras:v1.2.0

# Method 2: Using skopeo (direct registry-to-registry copy, no local storage needed)
skopeo copy \
  docker://registry.redhat.io/rhaii/vllm-cuda-rhel9:3.4.0 \
  docker://YOUR_LOCAL_REGISTRY/rhaii/vllm-cuda-rhel9:3.4.0

skopeo copy \
  docker://registry.redhat.io/rhelai1/mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5 \
  docker://YOUR_LOCAL_REGISTRY/rhelai1/mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5

skopeo copy \
  docker://ghcr.io/oras-project/oras:v1.2.0 \
  docker://YOUR_LOCAL_REGISTRY/oras-project/oras:v1.2.0
```

#### Alt 2: HuggingFace

The model is downloaded directly from HuggingFace Hub at pod startup. No image mirroring needed, but the cluster must have internet access and a HuggingFace token.

Prepare your HuggingFace access token from https://huggingface.co/settings/tokens.

#### Alt 3: Preloaded

The model files are already on a PersistentVolume. Use this when you have pre-populated the storage through other means (e.g., `kubectl cp`, NFS mount, or a separate download job). No image mirroring needed for the model.

You still need the vLLM runtime image accessible from your cluster (mirror it if air-gapped).

### Step 3: Configure values.yaml

Edit `values.yaml` and update the `YOUR_*` placeholders:

| Placeholder | Description | Example |
|---|---|---|
| `YOUR_STORAGE_CLASS` | Your cluster's StorageClass | `gp2`, `managed-premium`, `local-path` |
| `YOUR_PULL_SECRET` | Existing image pull secret name (if applicable) | `my-registry-pull-secret` |
| `YOUR_NODE_LABEL` | GPU node label for `nodeSelector` | `dedicated: rhai` |
| `YOUR_NODE_TAINT` | GPU node taint for `tolerations` | `dedicated=rhai:NoSchedule` |

Then apply the settings for your chosen mode:

**Alt 1 (OCI)** -- If using a local registry mirror, update the image references:

```yaml
vllm:
  image: YOUR_LOCAL_REGISTRY/rhaii/vllm-cuda-rhel9
model:
  source: oci    # this is the default
  ociImage: YOUR_LOCAL_REGISTRY/rhelai1/mistral-small-3-1-24b-instruct-2503-quantized-w4a16:1.5
  orasImage: YOUR_LOCAL_REGISTRY/oras-project/oras:v1.2.0
```

**Alt 2 (HuggingFace)** -- Set the model source and token:

```yaml
model:
  source: huggingface
  huggingfaceId: RedHatAI/Mistral-Small-3.1-24B-Instruct-2503-quantized.w4a16
huggingface:
  token: hf_YOUR_TOKEN
```

**Alt 3 (Preloaded)** -- Point to your existing PVC:

```yaml
model:
  source: preloaded
storage:
  existingClaim: YOUR_EXISTING_PVC_NAME
```

### Step 4: Install

> **Note:** `vllm.apiKey` is optional (default: disabled). Set it to enable API key authentication
> on all `/v1/*` endpoints. When set, requests must include `Authorization: Bearer YOUR_API_KEY`.
> The key is stored as a Kubernetes Secret, not in any file in this repo.

```bash
# Create namespace
kubectl create namespace rhai

# Option A: Use an existing image pull secret in your cluster
helm install rhaii . -n rhai \
  --set registrySecret.existingSecret=YOUR_PULL_SECRET \
  --set vllm.apiKey=YOUR_API_KEY

# Option B: Provide registry credentials directly
helm install rhaii . -n rhai \
  --set registrySecret.dockerconfigjson=$(cat ~/.config/containers/auth.json | base64) \
  --set vllm.apiKey=YOUR_API_KEY
```

### Step 5: Verify

```bash
# Watch pod startup (model download + loading takes several minutes)
kubectl get pods -n rhai -w

# Check init container logs (model download progress, OCI mode only)
kubectl logs -n rhai -l app.kubernetes.io/instance=rhaii -c fetch-model

# Check vLLM logs (model loading to GPU)
kubectl logs -n rhai -l app.kubernetes.io/instance=rhaii -c vllm -f

# Once pod shows 1/1 Running, test the API
kubectl port-forward -n rhai svc/rhaii-rhaii-vllm 8000:80

curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -d '{
    "model": "mistral-small-3.1-24b-instruct",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 100
  }'
```

## Accessing the Inference API

### Cluster-internal access (default)

The service is exposed as `ClusterIP` by default. Other pods in the cluster can access it via:

```
http://rhaii-rhaii-vllm.rhai.svc.cluster.local/v1/chat/completions
```

All `/v1/*` endpoints require an API key when `vllm.apiKey` is set:

```bash
curl http://rhaii-rhaii-vllm.rhai.svc.cluster.local/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -d '{"model": "mistral-small-3.1-24b-instruct", "messages": [{"role": "user", "content": "Hello!"}]}'
```

### External access (optional, not included in this chart)

For external access, configure an Ingress Controller (e.g., NGINX Ingress) with a NodePort backend. This is out of scope for this POC. A typical setup would be:

1. Install an Ingress Controller on your cluster
2. Change the service type: `--set service.type=NodePort`
3. Create an Ingress resource with TLS termination pointing to the service

### Network policy (optional)

To restrict access to authorized namespaces only, enable the NetworkPolicy:

```bash
helm install rhaii . -n rhai \
  --set networkPolicy.enabled=true \
  --set networkPolicy.allowFrom[0].namespaceSelector.matchLabels.kubernetes\\.io/metadata\\.name=YOUR_ALLOWED_NAMESPACE
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
| `vllm.apiKey` | `""` | API key for authentication on /v1/* endpoints (leave empty to disable) |
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
| `networkPolicy.enabled` | `false` | Enable NetworkPolicy to restrict ingress traffic |
| `networkPolicy.allowFrom` | `[{namespaceSelector: ...}]` | Allowed sources for ingress traffic |

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

**API key authentication test:**

```bash
kubectl port-forward -n rhai svc/rhaii-rhaii-vllm 8000:80

# Without API key → rejected
curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"mistral-small-3.1-24b-instruct","messages":[{"role":"user","content":"Hello"}]}'
# → {"error":"Unauthorized"}

# With correct API key → success
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -d '{
    "model": "mistral-small-3.1-24b-instruct",
    "messages": [{"role": "user", "content": "Hello! What model are you?"}],
    "max_tokens": 100
  }'
```

Successful response:

```json
{
  "id": "chatcmpl-993540dc941046b1",
  "object": "chat.completion",
  "model": "mistral-small-3.1-24b-instruct",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Hello! How can I assist you today?"
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 178,
    "total_tokens": 188,
    "completion_tokens": 10
  }
}
```

## Troubleshooting

See **[Troubleshooting Guide](examples/troubleshooting.md)** for common issues and solutions, including:
- PVC stuck in Pending
- Tokenizer errors
- Pod restart loops during model loading
- GPU scheduling deadlocks
