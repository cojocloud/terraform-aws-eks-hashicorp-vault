# Implementation Guide — Deep Dive into Every File and Decision

This document explains what each file does, why design decisions were made, what pitfalls to avoid, and how everything connects. Read this alongside the README when you want to understand the *why* behind the *what*.

---

## Table of Contents

1. [How All Files Connect](#1-how-all-files-connect)
2. [backend.tf — Remote State](#2-backendtf--remote-state)
3. [provider.tf — Provider Configuration](#3-providertf--provider-configuration)
4. [variables.tf — Input Variables](#4-variablestf--input-variables)
5. [vpc.tf — Networking Foundation](#5-vpctf--networking-foundation)
6. [eks.tf — Kubernetes Cluster](#6-ekstf--kubernetes-cluster)
7. [iam.tf — Access Control](#7-iamtf--access-control)
8. [autoscaler-iam.tf — Autoscaler Permissions](#8-autoscaler-iamtf--autoscaler-permissions)
9. [autoscaler-manifest.tf — Autoscaler Workload](#9-autoscaler-manifesttf--autoscaler-workload)
10. [ebs_csi_driver.tf — Block Storage](#10-ebs_csi_drivertf--block-storage)
11. [helm-provider.tf — Helm Configuration](#11-helm-providertf--helm-configuration)
12. [helm-load-balancer-controller.tf — Ingress](#12-helm-load-balancer-controllertf--ingress)
13. [monitoring.tf — Observability](#13-monitoringtf--observability)
14. [Jenkinsfile — CI/CD Pipeline](#14-jenkinsfile--cicd-pipeline)
15. [values.yaml — Prometheus Configuration](#15-valuesyaml--prometheus-configuration)
16. [Fixes Applied to the Original Code](#16-fixes-applied-to-the-original-code)
17. [Lessons Learned from Real Implementation](#17-lessons-learned-from-real-implementation)
18. [Dependency Graph](#18-dependency-graph)

---

## 1. How All Files Connect

Terraform processes all `.tf` files in the directory as one configuration. There is no import between files — Terraform resolves the order of operations through resource references.

```
vpc.tf
  └──► eks.tf
         ├──► iam.tf
         ├──► autoscaler-iam.tf ──► autoscaler-manifest.tf
         ├──► ebs_csi_driver.tf
         ├──► helm-load-balancer-controller.tf
         └──► monitoring.tf
```

`eks.tf` is the central file. Every other workload file depends on the EKS cluster being up first. `provider.tf` and `backend.tf` are loaded before anything else.

---

## 2. backend.tf — Remote State

```hcl
terraform {
  backend "s3" {
    bucket         = "devops-projects-terraform-backends"
    key            = "eks/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-lock"
  }
}
```

**What it does:** Stores Terraform's state file in S3 instead of locally. The DynamoDB table acts as a lock — if two pipeline runs start at the same time, one waits until the other finishes.

**Why this matters:** The state file is what Terraform uses to know what it already created. If it's local and the Jenkins workspace gets cleaned (which it does — `cleanWs()` runs after every build), Terraform loses track of all resources. You can never safely destroy or update them again.

**What you must change:**
- Replace the bucket name with your own S3 bucket.
- The bucket and DynamoDB table must exist BEFORE you run `terraform init`. Terraform cannot create its own backend.
- The IAM credentials used must have S3 and DynamoDB access.

---

## 3. provider.tf — Provider Configuration

```hcl
provider "aws" {
  region = var.region
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.6"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.10.0"
    }
  }
  required_version = ">= 1.3.0"
}
```

**What each provider does:**
- `aws` — creates all AWS resources (VPC, EKS, IAM, etc.)
- `kubectl` — applies raw YAML manifests to Kubernetes (used for the Cluster Autoscaler)
- `helm` — installs Helm charts (Prometheus, AWS Load Balancer Controller)
- `kubernetes` — creates Kubernetes native resources (namespaces)

**Critical — Helm provider version must be pinned to `~> 2.6`:**

The original code used `>= 2.6.0` which allowed Terraform to install Helm provider v3.x. Version 3.x removed the `kubernetes {}` nested block syntax used in `helm-provider.tf`, causing this error:

```
Error: Unsupported block type
  on helm-provider.tf line 2, in provider "helm":
   2:   kubernetes {
Blocks of type "kubernetes" are not expected here.
```

The fix is `~> 2.6` which means "2.6 or newer, but not 3.0". This keeps the Helm provider on v2.x where the `kubernetes {}` block is valid.

---

## 4. variables.tf — Input Variables

```hcl
variable "cluster_name"    { type = string, default = "demo-eks-cluster" }
variable "cluster_version" { type = string, default = "1.32" }
variable "region"          { type = string, default = "us-east-1" }
variable "availability_zones" { type = list(any), default = ["us-east-1a", "us-east-1b"] }
variable "addons" { type = list(object({name = string, version = string})), default = [...] }
```

**EKS addon versions must match the cluster version.** The original code used EKS 1.27 with addon versions for 1.27. After upgrading to 1.32, addon versions were updated:

| Addon | Version for EKS 1.32 |
|-------|---------------------|
| kube-proxy | v1.32.0-eksbuild.2 |
| vpc-cni | v1.19.2-eksbuild.1 |
| coredns | v1.11.4-eksbuild.2 |
| aws-ebs-csi-driver | v1.38.1-eksbuild.1 |

To verify exact default versions available for your cluster version:
```bash
aws eks describe-addon-versions --kubernetes-version 1.32 --output table
```

**`cluster_version` must be `type = string`, not `type = number`.** Kubernetes versions like `"1.32"` are strings — using `number` is semantically wrong and breaks if a patch version (e.g., `"1.32.1"`) is ever needed.

---

## 5. vpc.tf — Networking Foundation

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"
  cidr            = "10.0.0.0/16"
  private_subnets = ["10.0.0.0/19", "10.0.32.0/19"]
  public_subnets  = ["10.0.64.0/19", "10.0.96.0/19"]
  enable_nat_gateway = true
  single_nat_gateway = true
  ...
}
```

**Subnet design:**

| Subnet Type | CIDRs | Contains |
|-------------|-------|----------|
| Public | 10.0.64.0/19, 10.0.96.0/19 | NAT Gateway, internet-facing ALBs |
| Private | 10.0.0.0/19, 10.0.32.0/19 | EKS worker nodes |

Worker nodes are in private subnets — they have no public IP addresses. They reach the internet through the NAT Gateway in the public subnet.

**Subnet tags are required for the Load Balancer Controller to work:**
- Public subnets: `kubernetes.io/role/elb = 1` (for internet-facing ALBs)
- Private subnets: `kubernetes.io/role/internal-elb = 1` (for internal ALBs)

**`single_nat_gateway = true`** uses one NAT Gateway to save money (~$32/month vs ~$64 for two). The tradeoff is that if the AZ hosting the NAT Gateway goes down, nodes in the other AZ lose outbound internet access. Acceptable for dev/test, not for production.

---

## 6. eks.tf — Kubernetes Cluster

This is the most important file. It creates the EKS cluster, node groups, aws-auth ConfigMap, and the Kubernetes provider that all other workload files depend on.

**Key settings:**

```hcl
cluster_endpoint_private_access = true
cluster_endpoint_public_access  = true
```

Both true means the EKS API server is reachable from within the VPC (by nodes) and from the internet (by Jenkins/operators). For stricter security, set `cluster_endpoint_public_access = false` and access only via VPN.

```hcl
enable_irsa = true
```

IRSA (IAM Roles for Service Accounts) lets Kubernetes pods assume IAM roles without storing AWS credentials. Used by the Cluster Autoscaler and Load Balancer Controller.

**Node group:**
```hcl
general = {
  desired_size   = 2
  min_size       = 2
  max_size       = 10
  instance_types = ["t3.large"]
  capacity_type  = "ON_DEMAND"
}
```

2 nodes by default, scalable to 10 by the Cluster Autoscaler. `t3.large` = 2 vCPU + 8GB RAM each.

**aws-auth ConfigMap:**
```hcl
manage_aws_auth_configmap = true
aws_auth_roles = [{
  rolearn  = module.eks_admins_iam_role.iam_role_arn
  username = module.eks_admins_iam_role.iam_role_name
  groups   = ["system:masters"]
}]
```

This maps the `eks-admin` IAM role to the `system:masters` Kubernetes group (cluster admin). Anyone who assumes this IAM role can run any `kubectl` command.

**Kubernetes provider uses exec-based token, not static token:**
```hcl
exec {
  api_version = "client.authentication.k8s.io/v1beta1"
  args        = ["eks", "get-token", "--cluster-name", data.aws_eks_cluster.default.id]
  command     = "aws"
}
```

EKS tokens expire after 15 minutes. Instead of a static token, the provider calls `aws eks get-token` each time it needs to authenticate. This requires AWS CLI to be installed wherever Terraform runs.

---

## 7. iam.tf — Access Control

Creates an IAM hierarchy for cluster access:

```
user1 (IAM User)
  └── eks-admin (IAM Group)
        └── allow-assume-eks-admin-iam-role (Policy: sts:AssumeRole)
              └── eks-admin (IAM Role) ← mapped in aws-auth ConfigMap
                    └── allow-eks-access (Policy: eks:DescribeCluster)
```

**Why role assumption instead of direct access?**

Users don't get Kubernetes permissions directly. They assume a role that has those permissions. Benefits:
- Revoke access by removing a user from the group — no cluster config changes needed
- Full CloudTrail audit of who assumed the role and when
- Can require MFA for role assumption

**`user1`** is a placeholder IAM user. Replace with real users or integrate with SSO.

---

## 8. autoscaler-iam.tf — Autoscaler Permissions

```hcl
module "cluster_autoscaler_irsa_role" {
  role_name                        = "cluster-autoscaler"
  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_ids   = [module.eks.cluster_id]
  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:cluster-autoscaler"]
    }
  }
}
```

Creates an IAM role scoped to exactly one Kubernetes service account (`kube-system:cluster-autoscaler`). The Cluster Autoscaler pod uses this role to call AWS ASG APIs and scale node groups up or down.

**How IRSA works:**
1. EKS provides an OIDC identity provider
2. The IAM role's trust policy allows tokens from that OIDC provider for the specific service account
3. The pod receives a JWT token via a projected volume
4. AWS SDK exchanges the JWT for temporary credentials — no static keys anywhere

---

## 9. autoscaler-manifest.tf — Autoscaler Workload

Deploys the Cluster Autoscaler using raw YAML manifests (via the `kubectl` provider). Creates:

- `ServiceAccount` — annotated with the IRSA role ARN
- `Role` + `RoleBinding` — namespace-scoped access to ConfigMaps
- `ClusterRole` + `ClusterRoleBinding` — cluster-wide access to nodes/pods
- `Deployment` — runs the autoscaler pod

**How autoscaling works:**
1. Pod enters `Pending` — no node has capacity
2. Autoscaler detects this via the Kubernetes API
3. Identifies which ASG can accommodate the pod
4. Calls AWS ASG API to increase `DesiredCapacity`
5. New EC2 instance joins the cluster
6. Pod is scheduled

Scale-in: if nodes are underutilized for 10 minutes, autoscaler removes them.

**Image registry was updated:**

Original code used `k8s.gcr.io` which was retired in March 2023. Fixed to:
```yaml
image: registry.k8s.io/autoscaling/cluster-autoscaler:v1.32.0
```

The autoscaler version must match the EKS cluster minor version (EKS 1.32 → autoscaler v1.32.x).

---

## 10. ebs_csi_driver.tf — Block Storage

```hcl
resource "aws_eks_addon" "addons" {
  for_each      = { for addon in var.addons : addon.name => addon }
  cluster_name  = module.eks.cluster_id
  addon_name    = each.value.name
  addon_version = each.value.version
}
```

Iterates the `addons` variable and creates managed EKS addons. The `aws-ebs-csi-driver` is the one that enables persistent storage — without it, Prometheus and any stateful workload cannot create PersistentVolumes backed by EBS.

---

## 11. helm-provider.tf — Helm Configuration

```hcl
provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.default.endpoint
    cluster_ca_certificate = base64decode(...)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", data.aws_eks_cluster.default.id]
      command     = "aws"
    }
  }
}
```

Same exec-based auth as the Kubernetes provider. Both providers must point to the same cluster with the same auth method.

**The `kubernetes {}` block requires Helm provider v2.x.** Helm provider v3.x changed this syntax — pinning to `~> 2.6` in `provider.tf` prevents Terraform from installing v3.x.

---

## 12. helm-load-balancer-controller.tf — Ingress

Deploys the AWS Load Balancer Controller via Helm. This controller watches Kubernetes `Ingress` and `Service` (type: LoadBalancer) resources and creates corresponding AWS ALBs and NLBs.

Without this controller:
- `Service` type LoadBalancer creates a deprecated classic ELB
- `Ingress` resources are ignored

With this controller, create an ALB by annotating your Ingress:
```yaml
annotations:
  kubernetes.io/ingress.class: alb
  alb.ingress.kubernetes.io/scheme: internet-facing
```

Uses an IRSA role scoped to `kube-system:aws-load-balancer-controller`.

---

## 13. monitoring.tf — Observability

```hcl
resource "time_sleep" "wait_for_kubernetes" {
  depends_on      = [module.eks]
  create_duration = "20s"
}

resource "kubernetes_namespace" "kube-namespace" {
  depends_on = [time_sleep.wait_for_kubernetes]
  metadata { name = "prometheus" }
}

resource "helm_release" "prometheus" {
  chart   = "kube-prometheus-stack"
  version = "51.3.0"
  ...
}
```

**Why the 20-second sleep:** After EKS reports "ready", the Kubernetes API takes a few more seconds to become fully responsive. Without this delay, `kubernetes_namespace` fails with a connection error. This is a known race condition workaround.

**What the Prometheus stack installs:**

| Component | Purpose |
|-----------|---------|
| Prometheus | Scrapes and stores metrics |
| Alertmanager | Routes alerts to email/Slack/PagerDuty |
| kube-state-metrics | Kubernetes object state as metrics |
| node-exporter | OS metrics from each node (CPU, memory, disk) |

**Prometheus memory limit was fixed** — the original 50Mi limit caused immediate OOMKill. Updated to 1Gi limit / 512Mi request.

---

## 14. Jenkinsfile — CI/CD Pipeline

### Pipeline Design — ACTION Parameter

The original pipeline had a blocking `input()` prompt after provisioning to ask if the user wanted to destroy. This caused the pipeline to **hang indefinitely** after a successful apply, waiting for someone to click a button.

The redesign uses a pipeline **parameter selected before the run**:

```groovy
parameters {
    choice(
        name: 'ACTION',
        choices: ['Apply', 'Destroy'],
        description: 'Select Apply to provision or Destroy to tear down.'
    )
}
```

- **Apply** run: runs Fetch Credentials → Checkout → Install Terraform → Init → Plan+Apply → Verify
- **Destroy** run: runs Fetch Credentials → Checkout → Install Terraform → Init → Destroy

Each stage uses `when { expression { return params.ACTION == 'Apply' } }` to control which stages execute.

### Stage: Fetch Credentials from Vault

Jenkins stores only three non-sensitive values: `VAULT_URL`, `vault-role-id`, `vault-secret-id`. The pipeline uses these to authenticate to Vault and retrieve the actual secrets at runtime.

The retrieved secrets are written to `vault_env.sh` — a temporary shell script that subsequent stages source to load credentials into their environment. The `cleanWs()` in the `post` block deletes the workspace (including this file) after every run.

### Stage: Checkout Source Code

```groovy
sh '''
git clone https://github.com/cojocloud/terraform-aws-eks-hashicorp-vault.git
'''
```

The repo is public so no credentials are needed here. The GIT_TOKEN from Vault is available for private repos if needed.

**Critical naming detail:** The cloned directory is named `terraform-aws-eks-hashicorp-vault` (matching the repo name). All subsequent stages `cd` into this directory. If this name is wrong, every Terraform stage fails with `No such file or directory`.

### Stage: Install Terraform

Downloads Terraform 1.9.0 into the Jenkins workspace on every run. This is slightly slow (~30s) but ensures the correct version is always used regardless of what is installed on the server.

### Stage: Terraform Init

Sources `vault_env.sh` to load AWS credentials, then runs `terraform init`. This downloads all providers and connects to the S3 backend. The `.terraform.lock.hcl` file generated here records the exact provider versions — commit this file to your repo.

### Stage: Terraform Plan and Apply

Runs plan then apply in sequence. EKS provisioning takes 15–20 minutes. The `vault_env.sh` must be sourced in every stage because each `sh` block runs in a separate shell process — environment variables do not persist between stages.

### Stage: Update Kubeconfig and Verify

```bash
CLUSTER_NAME=$(aws eks list-clusters --region us-east-1 --query 'clusters[0]' --output text)
```

Retrieves the cluster name dynamically. Note: `clusters[0]` returns the first cluster alphabetically — if you have multiple EKS clusters in the account, this may pick the wrong one. Replace with the hardcoded name `demo-eks-cluster` for reliability.

Updates the kubeconfig for the Jenkins user at `/var/lib/jenkins/.kube/config` and verifies connectivity with `kubectl get nodes`.

---

## 15. values.yaml — Prometheus Configuration

Overrides Helm chart defaults for the Prometheus stack:

| Setting | Value | Why |
|---------|-------|-----|
| `server.retention` | `15d` | Keep 15 days of metrics |
| `server.persistentVolume.enabled` | `true` | Use EBS for data persistence |
| `server.persistentVolume.size` | `8Gi` | 8GB EBS volume |
| `server.service.type` | `ClusterIP` | Not exposed externally — use port-forward |
| `alertmanager.enabled` | `true` | Deploy Alertmanager |
| `kube-state-metrics.enabled` | `true` | Deploy kube-state-metrics |
| `prometheus-node-exporter.enabled` | `true` | Deploy node exporter on every node |

---

## 16. Fixes Applied to the Original Code

All of these were bugs or outdated configurations in the original repo that needed fixing:

| File | Original Issue | Fix Applied |
|------|---------------|------------|
| `autoscaler-manifest.tf` | Image used retired `k8s.gcr.io` registry; version v1.23.1 mismatched with EKS | Changed to `registry.k8s.io/autoscaling/cluster-autoscaler:v1.32.0` |
| `variables.tf` | `cluster_version` typed as `number` | Changed to `type = string` |
| `variables.tf` | EKS 1.27 end-of-life | Upgraded to 1.32 with matching addon versions |
| `provider.tf` | Missing `aws` and `kubernetes` in `required_providers` | Added both with version constraints |
| `provider.tf` | Helm version `>= 2.6.0` allowed v3.x (breaking) | Pinned to `~> 2.6` |
| `monitoring.tf` | Prometheus memory limit 50Mi caused OOMKill | Raised to 1Gi limit / 512Mi request |
| `Jenkinsfile` | Debug echo lines printed AWS credentials in plain text | Removed |
| `Jenkinsfile` | Blocking `input()` prompt caused pipeline to hang after apply | Replaced with `ACTION` parameter chosen before run |
| `Jenkinsfile` | Terraform 1.3.4 (outdated) | Updated to 1.9.0 |
| `Jenkinsfile` | Wrong repo directory name `aws-eks-terraform` | Fixed to `terraform-aws-eks-hashicorp-vault` |

---

## 17. Lessons Learned from Real Implementation

These are real issues encountered during implementation of this project:

**Vault must run as a systemd service, not a background process.**
Running `vault server -dev &` dies when the SSH session ends. Always use a systemd service file with `Restart=on-failure`. Check with `sudo systemctl status vault`.

**Vault CLI must be installed on the Jenkins server, not just the Vault server.**
The pipeline runs shell commands (`vault write`, `vault kv get`) on the Jenkins server. The Jenkins server needs the Vault CLI binary to execute these — it does not need to run the Vault server.

**VAULT_URL must be the Vault server's private IP, not localhost or the public IP.**
- `127.0.0.1` — means the Jenkins server itself. Vault is not running there. Fails with `connection refused`.
- Public IP — works but is slower and costs egress. Don't use for internal VPC communication.
- Private IP (`172.31.x.x`) — correct. Both servers are in the same VPC. Free and reliable.

**Vault dev mode wipes everything on restart.**
Dev mode stores all secrets in memory. Every Vault restart = all secrets, policies, AppRole config gone. You must re-run the full Vault configuration after every restart. The `-dev-root-token-id=root` flag sets a fixed root token so you don't have to look it up each time.

**KV v2 policy paths include `/data/` — KV v1 paths do not.**
The `secret/` mount (default in dev mode) is KV v2. When Vault CLI reads `secret/github`, the API call goes to `/v1/secret/data/github`. The policy must allow `secret/data/github`, not `secret/github`. The `aws/` mount (enabled manually with `vault secrets enable -path=aws kv`) is KV v1 — no `/data/` prefix.

**Avoid heredoc in shell commands when possible.**
The `<<EOF ... EOF` pattern fails if the closing `EOF` has any spaces before it, or if the command is split across lines in a way the shell can't parse. Write multiline content to a file with `cat > /tmp/file.hcl << 'EOF'` and then reference the file.

**Never bind Vault to the EC2 public IP directly.**
EC2 instances don't own their public IP — AWS handles it through NAT. You cannot bind a server process to a public IP. Always bind to `0.0.0.0` (all interfaces) or the private IP (`172.31.x.x`). External traffic still reaches it via the public IP.

**Helm provider v3.x is a breaking change — pin to `~> 2.6`.**
The `kubernetes {}` nested block in `helm-provider.tf` is only valid in Helm provider v2.x. Without pinning, Terraform installs the latest version which may be v3.x, causing `Unsupported block type` errors on `terraform plan`.

**The pipeline's `Checkout Source Code` directory name must match the cloned repo.**
`git clone` creates a directory named after the repo (e.g., `terraform-aws-eks-hashicorp-vault`). Every subsequent stage that does `cd terraform-aws-eks-hashicorp-vault` must use the exact same name. A mismatch causes every Terraform stage to fail.

---

## 18. Dependency Graph

The order Terraform creates resources:

```
1. VPC + Subnets + NAT Gateway (vpc.tf)
   └── 2. EKS Cluster + Node Group (eks.tf)
         ├── 3a. aws-auth ConfigMap (eks.tf)
         ├── 3b. IAM Roles and Policies (iam.tf)
         ├── 3c. IRSA Roles (autoscaler-iam.tf, helm-load-balancer-controller.tf)
         ├── 3d. EKS Managed Addons (ebs_csi_driver.tf)
         └── 3e. [20-second sleep] (monitoring.tf)
               ├── 4a. prometheus Namespace (monitoring.tf)
               │     └── 5a. Prometheus Helm Release (monitoring.tf)
               ├── 4b. Cluster Autoscaler Manifests (autoscaler-manifest.tf)
               └── 4c. AWS LBC Helm Release (helm-load-balancer-controller.tf)
```

Resources at the same level can be created in parallel. Terraform handles this automatically.

**Destroy runs this graph in reverse** — Helm releases and Kubernetes resources are removed before the EKS cluster, and the EKS cluster before the VPC. This ordering is critical: deleting the VPC while EKS still exists leaves orphaned resources that cannot be cleaned up through Terraform.
