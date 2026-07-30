# Swapping Models

This guide shows how to replace the default model with a different one.

## What to change in values.yaml

When swapping models, update these fields:

| Field | Description | Example |
|---|---|---|
| `model.ociImage` | OCI model image (if using `source: oci`) | `registry.redhat.io/rhelai1/granite-3-1-8b-instruct-quantized-w8a8:1.5` |
| `model.huggingfaceId` | HuggingFace model ID (if using `source: huggingface`) | `RedHatAI/granite-3.1-8b-instruct` |
| `model.servedName` | Model name exposed via the API | `granite-3.1-8b-instruct` |

You may also need to adjust server parameters (e.g., `maxModelLen`, `enforceEager`) depending on the new model's size and GPU memory requirements. See the [Optimization Guide](optimization-guide.md) for details.

## Step by step

### 0. Mirror the new model (air-gapped clusters only)

If your cluster cannot reach `registry.redhat.io` directly, mirror the new model's OCI image to your local registry before proceeding. See the [Deployment Guide (Alt 1: OCI)](../README.md#step-2-prepare-images-choose-one-mode) for mirror instructions.

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

## Verified example: Granite-3.1-8B W8A8

I deployed [Granite-3.1-8B W8A8](https://huggingface.co/RedHatAI/granite-3.1-8b-instruct-quantized.w8a8) on a single NVIDIA L4 (24GB) using [example-granite-values.yaml](example-granite-values.yaml) and ran the SQL test script:

```bash
./examples/test-text-to-sql.sh http://localhost:8000 YOUR_API_KEY granite-3.1-8b-instruct
```

```
TEST: Basic aggregation with JOIN
Question: Find the top 3 departments with the highest average salary, show department name,
          average salary, and employee count.
Generated SQL:
SELECT d.name AS department_name, AVG(e.salary) AS average_salary, COUNT(e.id) AS employee_count
FROM employees e
JOIN departments d ON e.department = d.name
GROUP BY d.name
ORDER BY average_salary DESC
LIMIT 3;

TEST: HAVING clause with calculated field
Question: List all departments where the total employee salary exceeds the department budget,
          with the overspend amount, sorted by overspend descending.
Generated SQL:
SELECT d.name AS department, SUM(e.salary) AS total_salary, d.budget,
       SUM(e.salary) - d.budget AS overspend
FROM employees e
JOIN departments d ON e.department = d.name
GROUP BY d.name, d.budget
HAVING SUM(e.salary) > d.budget
ORDER BY overspend DESC;

TEST: Multi-table JOIN with filter
Question: Show all active projects along with their department name and the number of employees
          in that department.
Generated SQL:
SELECT p.name AS project_name, d.name AS department_name, COUNT(e.id) AS num_employees
FROM projects p
JOIN departments d ON p.department_id = d.id
JOIN employees e ON d.id = e.department
WHERE p.status = 'active'
GROUP BY p.id, d.id;
```

Comparison with the default Mistral-Small-3.1-24B model:

| | Mistral-Small 24B W4A16 | Granite 8B W8A8 |
|---|---|---|
| Model loading | 14.05 GiB, 112s | 7.84 GiB, 51s |
| Available KV cache | 5.18 GiB | 11.41 GiB |
| KV cache pool | 33,904 tokens | 74,784 tokens |
| Max concurrency (8192 tokens) | ~4.1x | ~9.1x |
| CUDA graphs | Off (not enough memory) | On |

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
