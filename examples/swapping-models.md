# Swapping Models

This guide shows how to replace the default model with a different one.

## What to change in values.yaml

When swapping models, update these fields:

| Field | Description | Example |
|---|---|---|
| `model.ociImage` | OCI model image (if using `source: oci`) | `registry.redhat.io/rhelai1/granite-3-1-8b-instruct-quantized-w8a8:1.5` |
| `model.huggingfaceId` | HuggingFace model ID (if using `source: huggingface`) | `RedHatAI/granite-3.1-8b-instruct` |
| `model.servedName` | Model name exposed via the API | `granite-3.1-8b-instruct` |

You may also need to adjust server parameters depending on the new model's size and requirements:

| Field | Why it may need changing |
|---|---|
| `vllm.args.maxModelLen` | Different models support different context lengths |
| `vllm.args.tensorParallelSize` | Larger models may require multiple GPUs |
| `vllm.args.enforceEager` | Smaller models may have enough GPU headroom to disable this |
| `resources.limits.nvidia.com/gpu` | Must match `tensorParallelSize` |

## Step by step

### 1. Delete the existing PVC (model cache)

The PVC contains the previous model's files. It must be deleted so the new model can be downloaded:

```bash
helm uninstall rhaii -n rhai
kubectl delete pvc -n rhai --all
```

### 2. Create or update a values file

Instead of editing the default `values.yaml`, you can create a separate values file for the new model. See [example-granite-values.yaml](example-granite-values.yaml) for a complete example.

Example: switching from [Mistral-Small-3.1-24B W4A16](https://huggingface.co/RedHatAI/Mistral-Small-3.1-24B-Instruct-2503-quantized.w4a16) to [Granite-3.1-8B W8A8](https://huggingface.co/RedHatAI/granite-3.1-8b-instruct-quantized.w8a8):

```yaml
model:
  ociImage: registry.redhat.io/rhelai1/granite-3-1-8b-instruct-quantized-w8a8:1.5
  servedName: granite-3.1-8b-instruct

vllm:
  args:
    maxModelLen: 8192       # Granite 8B is smaller, can afford longer context
    enforceEager: false     # smaller model = more GPU headroom for CUDA graphs
    tokenizerMode: auto
```

### 3. Install

```bash
# Using a separate values file (-f) with environment-specific overrides (--set)
helm install rhaii . -n rhai \
  -f examples/example-granite-values.yaml \
  --set registrySecret.existingSecret=YOUR_PULL_SECRET \
  --set vllm.apiKey=YOUR_API_KEY
```

### 4. Verify

```bash
# Wait for model download + GPU loading
kubectl get pods -n rhai -w

# Test with the new model name
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -d '{
    "model": "granite-3.1-8b-instruct",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 100
  }'
```

## Finding compatible models

- **Red Hat Validated Models**: [Choose a validated model for reliable serving](https://docs.redhat.com/en/documentation/red_hat_ai/3/html-single/validated_models/index) -- official model support matrix with compatibility, modelcar image paths, and performance data
- **HuggingFace**: [RedHatAI on HuggingFace](https://huggingface.co/RedHatAI) -- all available Red Hat AI models with quantization variants and deployment examples

### GPU memory considerations

When choosing a model, estimate whether it fits on your GPU:

| Quantization | Approximate weight size | Single L4 (24GB)? |
|---|---|---|
| W4A16 (4-bit weights) | ~0.5 GB per billion params | Up to ~24B models |
| W8A8 (8-bit weights) | ~1 GB per billion params | Up to ~10-12B models |
| FP8 (8-bit float) | ~1 GB per billion params | Up to ~10-12B models |
| FP16/BF16 (no quantization) | ~2 GB per billion params | Up to ~5B models |

For example, Mistral-Small-3.1-24B at W4A16 takes ~14 GB, leaving room for KV cache on a 24 GB L4. The same model at W8A8 would take ~24 GB, leaving no room for KV cache.
