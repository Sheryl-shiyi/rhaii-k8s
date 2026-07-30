# Optimization Guide

This guide provides an overview of tunable parameters and examples from our POC testing. It is not exhaustive. The optimal configuration depends on your specific hardware, model, and use case. For official vLLM optimization documentation, see the [Reference](#reference) section.

## Overview

There are three categories of parameters you can tune:

| Category | What it affects | Requires Pod restart? | Where to change |
|---|---|---|---|
| **Server parameters** | Throughput, latency, GPU memory usage | Yes (~2-3 min reload) | `values.yaml` or `helm upgrade --set` |
| **Request parameters** | Output quality, creativity, length | No | API call (`curl` / application code) |
| **Model-level** | Model size, accuracy, speed | Yes (full redeployment) | Swap model in `values.yaml` ([guide](swapping-models.md)) |

### How to modify server parameters

There are three ways to change server parameters, each with different trade-offs:

| Method | Command | Tracked in git? | Notes |
|---|---|---|---|
| Edit `values.yaml` + upgrade | `helm upgrade rhaii .` | Yes | Recommended for permanent changes |
| Override via `--set` | `helm upgrade rhaii . --set vllm.args.maxModelLen=8192` | No | Quick experiments; overrides revert if not repeated on next upgrade |
| Direct edit | `kubectl edit deployment -n rhai rhaii-rhaii-vllm` | No | Fastest for testing; **next `helm upgrade` will overwrite your changes** |

All three methods trigger a Pod restart. The model is already cached on the PVC, so only GPU loading time (~2-3 minutes) is needed, not a full re-download.

## Server Parameters

These are the vLLM engine arguments configured in `values.yaml` under `vllm.args`. They control how vLLM runs on the GPU and directly impact performance.

### Core parameters (in values.yaml)

#### `tensorParallelSize` (default: 1)

Distributes the model across multiple GPUs. Set this to the number of GPUs available.

```bash
# Example: use 2 GPUs
helm upgrade rhaii . -n rhai --set vllm.args.tensorParallelSize=2
```

With a single GPU (our POC setup), this must stay at 1.

#### `maxModelLen` (default: 4096)

Maximum context length in tokens (input + output combined). This limits how long a single request's context (input + output) can be.

Increasing `maxModelLen` does not consume more GPU memory by itself. vLLM allocates a fixed KV cache pool based on available GPU memory, and `maxModelLen` only controls how much of that pool a single request can use. A higher value allows longer conversations but reduces the maximum number of concurrent requests.

**Tips to find the right value:**

1. Start with a value (e.g., 4096 or 8192)
2. Check the vLLM startup logs for the actual KV cache allocation and concurrency

```bash
helm upgrade rhaii . -n rhai --set vllm.args.maxModelLen=8192

# After Pod restarts (~2-3 min), check the logs:
kubectl logs -n rhai -l app.kubernetes.io/instance=rhaii -c vllm | grep -iE "KV cache|concurrency|Model loading|Available KV"
```

> **Experiment example** (single NVIDIA L4 24GB, Mistral-Small-3.1-24B W4A16)
>
> I tested two `maxModelLen` values on the POC environment. The key logs from vLLM:
>
> ```
> Model loading took 14.05 GiB memory
> Available KV cache memory: 5.18 GiB
> GPU KV cache size: 33,904 tokens
> ```
>
> vLLM first loads the model (14.05 GB), then measures the remaining GPU memory (5.18 GB), and allocates it entirely to the KV cache pool (33,904 tokens). This pool size stays the same regardless of `maxModelLen`:
>
> | maxModelLen | KV cache pool | Max concurrency | Status |
> |---|---|---|---|
> | 4096 | 33,904 tokens | ~8.3 concurrent requests | Started successfully |
> | 8192 | 33,904 tokens | ~4.1 concurrent requests | Started successfully |
>
> **Takeaway:** The default `maxModelLen=4096` is very conservative for this setup. Setting it to 8192 still allows ~4 concurrent requests, which is sufficient for most POC workloads. Choose the value based on your expected request length vs. concurrency needs.

#### `gpuMemoryUtilization` (default: 0.90)

Fraction of GPU memory vLLM is allowed to use (0.0 to 1.0). Higher values allocate more memory for KV cache but increase OOM risk.

```bash
# Example: increase to 0.95
helm upgrade rhaii . -n rhai --set vllm.args.gpuMemoryUtilization=0.95
```

| Value | Use case |
|---|---|
| 0.80 | Conservative, for shared GPU or unstable environments |
| 0.90 | Default, safe for most deployments |
| 0.95 | Aggressive, maximizes KV cache; do not exceed 0.95 |

#### `enforceEager` (default: true)

When `true`, disables CUDA Graphs optimization. CUDA Graphs pre-record GPU operations for faster execution, but require additional GPU memory (~1-2 GB).

```bash
# Example: enable CUDA Graphs (requires sufficient GPU memory headroom)
helm upgrade rhaii . -n rhai --set vllm.args.enforceEager=false
```

| Setting | Inference speed | GPU memory |
|---|---|---|
| `true` (current) | Slower | Saves ~1-2 GB |
| `false` | Faster | Uses ~1-2 GB more |

On a 24 GB L4 with a 14 GB model, memory is tight, so this defaults to `true`. If you have a larger GPU (e.g., A100 80 GB), set this to `false` for better performance.

#### `tokenizerMode` (default: auto)

Controls which tokenizer library to use. `auto` lets vLLM detect the correct tokenizer from the model files.

Generally, do not change this unless you encounter tokenizer-related errors.

### Tips for server parameter tuning

1. **Change one parameter at a time** and measure the impact before changing another.
2. **Each change requires ~2-3 minutes** for the model to reload to GPU (the model files on PVC are reused, no re-download).
3. **If the Pod OOMs or crash-loops**, reduce `maxModelLen` or `gpuMemoryUtilization`, or re-enable `enforceEager`.

## Request Parameters

These parameters are passed in each API call and do **not** require a Pod restart. They control the quality and behavior of the model's output.

### Key parameters

| Parameter | Default | Description | Recommendation for SQL |
|---|---|---|---|
| `temperature` | 1.0 | Controls randomness. 0.0 = deterministic, higher = more creative. | **0.0 - 0.1** (SQL needs precision) |
| `top_p` | 1.0 | Nucleus sampling. Only tokens within this cumulative probability are considered. | 0.90 - 0.95 |
| `max_tokens` | model max | Maximum number of tokens to generate. | 300-500 (enough for complex SQL) |
| `frequency_penalty` | 0.0 | Penalizes repeated tokens. Higher values reduce repetition. | 0.0 (SQL may legitimately repeat keywords) |

### Example: temperature comparison

```bash
# temperature=0.0 (deterministic, same output every time)
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -d '{
    "model": "mistral-small-3.1-24b-instruct",
    "messages": [
      {"role": "system", "content": "Generate SQL from natural language. Output only the SQL query."},
      {"role": "user", "content": "Count employees per department"}
    ],
    "temperature": 0.0,
    "max_tokens": 200
  }'
# Output: SELECT department, COUNT(*) FROM employees GROUP BY department;
# (same result every time)

# temperature=0.7 (more creative, output varies between calls)
# Same request but with "temperature": 0.7
# Output might vary: sometimes adds ORDER BY, aliases, or different formatting
```

For Text-to-SQL and other structured output tasks, use `temperature: 0.0` for consistent, reproducible results.

### System prompt optimization

The system prompt has the **largest impact on output quality** among all request-level configurations. It tells the model how to behave and what format to use.

**Basic prompt (used in the test script):**

```
You are a SQL expert. Given the following database schema and a natural language
question, generate the correct SQL query. Only output the SQL query, no explanation.

Schema:
- table: employees (id INT, name VARCHAR, department VARCHAR, salary DECIMAL, hire_date DATE)
- table: departments (id INT, name VARCHAR, manager_id INT, budget DECIMAL)
```

**Optimized prompt (better results):**

```
You are a SQL expert for a PostgreSQL database. Generate syntactically correct SQL
queries based on the schema below. Rules:
1. Output ONLY the SQL query, no explanations or markdown formatting.
2. Always use explicit JOIN syntax (never implicit joins in WHERE).
3. Use table aliases (e for employees, d for departments, p for projects).
4. Handle NULL values where appropriate.

Schema:
CREATE TABLE employees (
  id INT PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  department VARCHAR(100) REFERENCES departments(name),
  salary DECIMAL(10,2),
  hire_date DATE
);
CREATE TABLE departments (
  id INT PRIMARY KEY,
  name VARCHAR(100) UNIQUE NOT NULL,
  manager_id INT REFERENCES employees(id),
  budget DECIMAL(12,2)
);

Example:
Q: How many employees are in each department?
A: SELECT d.name, COUNT(e.id) AS employee_count FROM departments d LEFT JOIN employees e ON d.name = e.department GROUP BY d.name;
```

Key improvements:
- **Specify the database dialect** (PostgreSQL vs MySQL vs SQLite have different syntax)
- **Use CREATE TABLE** instead of shorthand (gives the model data types and constraints)
- **Add explicit rules** for output format and SQL style
- **Include a few-shot example** (shows the expected format, drastically improves consistency)

## Reference

- [Practical strategies for vLLM performance tuning (Red Hat Developer)](https://developers.redhat.com/articles/2026/03/03/practical-strategies-vllm-performance-tuning)
- [vLLM Engine Arguments - Full List (v0.18.0)](https://docs.vllm.ai/en/v0.18.0/configuration/engine_args.html)
- [vLLM Optimization and Tuning](https://docs.vllm.ai/en/v0.18.0/configuration/optimization/)
