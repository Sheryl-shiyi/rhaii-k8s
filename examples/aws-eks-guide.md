# Full Deployment Guide: AWS EKS from Scratch

This guide walks through setting up an EKS cluster with GPU support and deploying RHAII, based on our actual tested deployment.

## Prerequisites

Install the following CLI tools:

```bash
# AWS CLI (https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
aws --version

# eksctl (https://eksctl.io/installation/)
brew install eksctl    # macOS

# kubectl and helm
brew install kubectl helm    # macOS
```

Configure AWS credentials:

```bash
aws configure
# Enter your AWS Access Key ID, Secret Access Key, and region (e.g., us-east-2)
```

## Step 1: Create EKS cluster

An example cluster config is provided in [eksctl-cluster.yaml](eksctl-cluster.yaml):

```bash
eksctl create cluster -f examples/eksctl-cluster.yaml
```

This creates:
- 2x `m5.xlarge` CPU nodes (system workloads)
- 1x `g6.xlarge` GPU node (1x NVIDIA L4, 24GB VRAM)
- NVIDIA device plugin (auto-installed by eksctl for GPU instances)

Cluster creation takes approximately 15-20 minutes.

## Step 2: Install EBS CSI driver

EKS requires the EBS CSI driver for dynamic PersistentVolume provisioning:

```bash
# Install the addon
eksctl create addon --name aws-ebs-csi-driver --cluster rhaii-poc --region us-east-2 --force

# Grant IAM permissions to node roles
SYSTEM_ROLE=$(aws iam list-roles --query "Roles[?contains(RoleName, 'system-NodeInstanceRole')].RoleName" --output text)
GPU_ROLE=$(aws iam list-roles --query "Roles[?contains(RoleName, 'gpu-l4-NodeInstanceRole')].RoleName" --output text)

aws iam attach-role-policy --role-name "$SYSTEM_ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
aws iam attach-role-policy --role-name "$GPU_ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy

# Restart CSI controller to pick up new permissions
kubectl rollout restart deployment ebs-csi-controller -n kube-system
```

## Step 3: Configure GPU node

Label and taint the GPU node to match the Helm chart's scheduling configuration:

```bash
# Find your GPU node name
GPU_NODE=$(kubectl get nodes -l role=gpu -o jsonpath='{.items[0].metadata.name}')

# Apply label and taint
kubectl label node $GPU_NODE dedicated=rhai
kubectl taint node $GPU_NODE dedicated=rhai:NoSchedule
```

## Step 4: Deploy RHAII

```bash
# Create namespace
kubectl create namespace rhai

# Login to Red Hat registry (on your local machine)
podman login registry.redhat.io

# Install the Helm chart
helm install rhaii . -n rhai \
  --set storage.storageClassName=gp2 \
  --set registrySecret.dockerconfigjson=$(cat ~/.config/containers/auth.json | base64)
```

## Step 5: Monitor and verify

```bash
# Watch pod progress
kubectl get pods -n rhai -w

# Check init container logs (model download, ~15GB)
kubectl logs -n rhai -l app.kubernetes.io/instance=rhaii -c fetch-model

# Check vLLM logs (model loading to GPU)
kubectl logs -n rhai -l app.kubernetes.io/instance=rhaii -c vllm -f
```

## Cleanup

```bash
# Remove RHAII deployment
helm uninstall rhaii -n rhai

# Delete EKS cluster (takes ~10 minutes)
eksctl delete cluster --name rhaii-poc --region us-east-2
```
