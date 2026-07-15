# Troubleshooting

Common issues encountered during RHAII deployment and their solutions.

## PVC stays in Pending state

**Symptom**: Pod cannot schedule, PVC shows `Pending`.

**Cause**: StorageClass not set or CSI driver not installed.

**Fix**: Verify your StorageClass exists (`kubectl get sc`) and set it in `values.yaml`. On EKS, install the EBS CSI driver addon (see [AWS EKS Guide](aws-eks-guide.md)).

## vLLM crashes with "No tokenizer file found"

**Symptom**: vLLM container exits with `ValueError: No tokenizer file found in directory: /model`.

**Cause**: Model files are incomplete (download was interrupted), or `tokenizerMode` is set incorrectly.

**Fix**:
1. Check that all model files exist: `kubectl exec -n rhai <pod> -c vllm -- ls /model/`
2. Ensure `vllm.args.tokenizerMode` is set to `auto` in `values.yaml`
3. If files are incomplete, delete the PVC and reinstall to trigger a fresh download:
   ```bash
   helm uninstall rhaii -n rhai
   kubectl delete pvc -n rhai --all
   helm install rhaii . -n rhai --set ...
   ```

## Pod keeps restarting during model loading

**Symptom**: Pod restarts repeatedly before the model is fully loaded to GPU.

**Cause**: The liveness probe fires before the model finishes loading.

**Fix**: This chart uses a `startupProbe` with `failureThreshold: 60` and `periodSeconds: 10`, allowing up to ~10 minutes for initial startup. If your model is larger, increase `failureThreshold` in `templates/deployment.yaml`.

## Pod stuck in Pending (GPU not available)

**Symptom**: Pod stays `Pending` with event "0/N nodes are available".

**Cause**: `nodeSelector` or `tolerations` don't match your GPU node configuration, or the GPU is already allocated to another pod.

**Fix**:
1. Check your GPU node labels: `kubectl get nodes --show-labels | grep gpu`
2. Check node taints: `kubectl describe node <gpu-node> | grep Taints`
3. Update `nodeSelector` and `tolerations` in `values.yaml` to match
4. Ensure no other pod is using the GPU: `kubectl describe node <gpu-node> | grep -A5 "Allocated resources"`

## Init container skips download on fresh PVC

**Symptom**: Init container logs show "Model already present, skipping pull" but model files are missing.

**Cause**: On ext4-formatted volumes (e.g., AWS EBS), a `lost+found` directory is created automatically, which can trick naive "is directory empty" checks.

**Fix**: This chart checks for the presence of `config.json` instead of checking if the directory is empty. If you still encounter this issue, delete the PVC and reinstall.

## GPU scheduling deadlock during rolling update

**Symptom**: New pod stays `Pending` while old pod is still `Running`, neither progresses.

**Cause**: With only 1 GPU and Kubernetes' default `RollingUpdate` strategy, the new pod can't start because the old pod holds the GPU, and the old pod won't terminate until the new one is ready.

**Fix**: This chart uses `strategy.type: Recreate`, which terminates the old pod before starting the new one. If you see this issue, verify the deployment strategy in `templates/deployment.yaml`.
