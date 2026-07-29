# Optimization Guide

This guide covers how to optimize the RHAII vLLM deployment for better performance and output quality.

## Overview

There are three categories of parameters you can tune:

| Category | What it affects | Requires Pod restart? | Where to change |
|---|---|---|---|
| **Server parameters** | Throughput, latency, GPU memory usage | Yes (~2-3 min reload) | `values.yaml` or `helm upgrade --set` |
| **Request parameters** | Output quality, creativity, length | No | API call (`curl` / application code) |
| **Model-level** | Model size, accuracy, speed | Yes (full redeployment) | Swap model in `values.yaml` |

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

Maximum context length in tokens (input + output combined). Larger values allow longer conversations but consume more GPU memory for KV cache.

```bash
# Example: increase to 8192
helm upgrade rhaii . -n rhai --set vllm.args.maxModelLen=8192
```

How to find the right value: start with a conservative value and increase gradually. vLLM validates `maxModelLen` against actual available GPU memory at startup. If the value is too high, the Pod will fail to start with an OOM error. If it starts successfully, the value is safe to use.

```bash
# Start conservative
helm upgrade rhaii . -n rhai --set vllm.args.maxModelLen=4096    # safe default

# Try increasing
helm upgrade rhaii . -n rhai --set vllm.args.maxModelLen=8192    # if this starts, it works
helm upgrade rhaii . -n rhai --set vllm.args.maxModelLen=16384   # keep going until OOM
```

Check the vLLM startup logs to see the actual KV cache allocation:

```bash
kubectl logs -n rhai -l app.kubernetes.io/instance=rhaii -c vllm | grep -i "kv cache"
```

#### `gpuMemoryUtilization` (default: 0.90)

Fraction of GPU memory vLLM is allowed to use (0.0 to 1.0). Higher values leave more room for KV cache but increase OOM risk.

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

On a 24 GB L4 with a 14 GB model, memory is tight, so we default to `true`. If you have a larger GPU (e.g., A100 80 GB), set this to `false` for better performance.

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

The system prompt has the **largest impact on output quality** among all request parameters. It tells the model how to behave and what format to use.

**Basic prompt (what our test script uses):**

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
