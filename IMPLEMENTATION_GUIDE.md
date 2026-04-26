# Implementation Guide — Understanding Every File and Decision

This document explains what each Terraform file does, why it exists, what would break without it, and what you need to customize before running this project yourself.

---

## Table of Contents

1. [How Terraform Files Connect](#how-terraform-files-connect)
2. [backend.tf — Remote State](#backendtf--remote-state)
3. [provider.tf — Provider Configuration](#providertf--provider-configuration)
4. [variables.tf — Input Variables](#variablestf--input-variables)
5. [vpc.tf — Networking Foundation](#vpctf--networking-foundation)
6. [eks.tf — Kubernetes Cluster](#ekstf--kubernetes-cluster)
7. [iam.tf — Access Control](#iamtf--access-control)
8. [autoscaler-iam.tf — Autoscaler Permissions](#autoscaler-iamtf--autoscaler-permissions)
9. [autoscaler-manifest.tf — Autoscaler Workload](#autoscaler-manifesttf--autoscaler-workload)
10. [ebs_csi_driver.tf — Block Storage](#ebs_csi_drivertf--block-storage)
11. [helm-provider.tf — Helm Configuration](#helm-providertf--helm-configuration)
12. [helm-load-balancer-controller.tf — Ingress](#helm-load-balancer-controllertf--ingress)
13. [monitoring.tf — Observability](#monitoringtf--observability)
14. [Jenkinsfile — CI/CD Pipeline](#jenkinsfile--cicd-pipeline)
15. [values.yaml — Prometheus Configuration](#valuesyaml--prometheus-configuration)
16. [Code Issues and Required Fixes](#code-issues-and-required-fixes)
17. [Dependency Graph](#dependency-graph)

---

## How Terraform Files Connect

Terraform processes all `.tf` files in the directory together as one configuration. There is no explicit import between files — Terraform resolves dependencies through resource and module references.

The key data flow is:

```
vpc.tf  ──► eks.tf  ──► iam.tf
                    ──► autoscaler-iam.tf ──► autoscaler-manifest.tf
                    ──► helm-load-balancer-controller.tf
                    ──► monitoring.tf
                    ──► ebs_csi_driver.tf
```

`eks.tf` is the central file. Once the EKS cluster exists, all the workload files (autoscaler, LBC, monitoring) can talk to it.

---

## backend.tf — Remote State

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

**What it does:** Stores the Terraform state file in S3 instead of locally. The DynamoDB table prevents two people (or two pipeline runs) from running `terraform apply` at the same time, which would corrupt state.

**Why it matters:** Without a remote backend, the state lives in a local `terraform.tfstate` file. This file is the source of truth for what Terraform "knows" about your infrastructure. If it gets lost or diverges between machines, you lose the ability to safely manage the infrastructure.

**What you MUST change before running:**
- Replace `devops-projects-terraform-backends` with your own S3 bucket name.
- The bucket and DynamoDB table must exist before `terraform init` runs.
- The AWS credentials used must have `s3:GetObject`, `s3:PutObject`, `dynamodb:PutItem`, `dynamodb:GetItem`, `dynamodb:DeleteItem` on these resources.

---

## provider.tf — Provider Configuration

```hcl
provider "aws" {
  region = var.region
}

terraform {
  required_providers {
    kubectl = { source = "gavinbunney/kubectl", version = ">= 1.14.0" }
    helm    = { source = "hashicorp/helm",      version = ">= 2.6.0" }
  }
  required_version = "~> 1.0"
}
```

**What it does:** Declares which provider plugins Terraform needs to download and what versions to accept. The AWS provider handles all `aws_*` resources. The kubectl provider handles raw YAML manifests (used by the autoscaler). The Helm provider installs Helm charts.

**Issue — missing kubernetes provider declaration:**
The `kubernetes` provider is used in `eks.tf` and `monitoring.tf` (for `kubernetes_namespace`, `kubernetes_config_map`) but is not declared in `required_providers`. This works because the `eks` module brings it in transitively, but it is fragile. Add this to be explicit:

```hcl
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
    version = ">= 2.6.0"
  }
  kubernetes = {
    source  = "hashicorp/kubernetes"
    version = ">= 2.10.0"
  }
}
```

**Why `~> 1.0` for Terraform version:** The tilde-arrow `~>` means "1.x but not 2.0". This is fine for Terraform 1.x, but Terraform 1.3.4 (what the Jenkinsfile installs) is outdated. Consider `>= 1.5.0` and update the Jenkinsfile download URL.

---

## variables.tf — Input Variables

```hcl
variable "cluster_name"       { default = "demo-eks-cluster" }
variable "cluster_version"    { type = number, default = 1.27 }
variable "region"             { default = "us-east-1" }
variable "availability_zones" { type = list, default = ["us-east-1a", "us-east-1b"] }
variable "addons"             { type = list(object({...})), default = [...] }
```

**What it does:** Defines all the tuneable inputs. Using variables instead of hardcoded values means you can run `terraform apply -var="region=us-west-2"` to target a different region without editing files.

**Issue — `cluster_version` type:** Using `number` for Kubernetes version works because `1.27` parses as a float, but this is semantically wrong. Kubernetes versions are strings (`"1.27"`). If the version has a patch (like `"1.27.3"`), it would fail as a number. Change to `type = string`.

**The addons list:**
The `addons` variable is iterated in `ebs_csi_driver.tf` to create `aws_eks_addon` resources. The four managed addons are:

| Addon | Purpose |
|-------|---------|
| `kube-proxy` | Network proxy on each node; maintains network rules |
| `vpc-cni` | Assigns AWS VPC IP addresses to pods |
| `coredns` | In-cluster DNS resolution for service discovery |
| `aws-ebs-csi-driver` | Allows Kubernetes to provision EBS volumes as PersistentVolumes |

**Note on `addons.json`:** There is also an `addons.json` file in the repository, but it is not referenced by any Terraform file. It appears to be documentation or a reference artifact from the original author. It has no effect on what gets deployed.

---

## vpc.tf — Networking Foundation

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  cidr            = "10.0.0.0/16"
  private_subnets = ["10.0.0.0/19", "10.0.32.0/19"]
  public_subnets  = ["10.0.64.0/19", "10.0.96.0/19"]

  enable_nat_gateway     = true
  single_nat_gateway     = true
  ...
}
```

**What it does:** Creates the entire network layer — VPC, subnets, route tables, an Internet Gateway, and a NAT Gateway.

**Subnet design:**
- **Public subnets** (`10.0.64.0/19`, `10.0.96.0/19`): Contain the NAT Gateway and any load balancers. The tag `kubernetes.io/role/elb = 1` tells the AWS Load Balancer Controller to place internet-facing ALBs here.
- **Private subnets** (`10.0.0.0/19`, `10.0.32.0/19`): Contain EKS worker nodes. Nodes have no public IPs; they reach the internet via the NAT Gateway. The tag `kubernetes.io/role/internal-elb = 1` enables internal ALBs in these subnets.

**Why `single_nat_gateway = true`:** Using one NAT Gateway saves money (~$32/month vs ~$64/month for two). The downside is that if `us-east-1a` has an outage, nodes in `us-east-1b` lose outbound internet access. For production, set `one_nat_gateway_per_az = true` and `single_nat_gateway = false`.

**CIDR math:**
- `/19` gives 8,190 usable IPs per subnet.
- The VPC has `/16` = 65,536 IPs total.
- Only 4 subnets are defined, leaving the rest of the CIDR available for future expansion.

---

## eks.tf — Kubernetes Cluster

This is the most important file. It creates the EKS cluster, the managed node group, configures the aws-auth ConfigMap, and sets up the Kubernetes provider for the rest of Terraform.

### EKS Cluster Module

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "18.29.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets
  enable_irsa = true
  ...
}
```

**`cluster_endpoint_private_access = true` + `cluster_endpoint_public_access = true`:** The EKS API server is accessible both from within the VPC (by worker nodes) and from the internet (by you/Jenkins). For stricter security, set `cluster_endpoint_public_access = false` and access via a VPN or bastion host.

**`subnet_ids = module.vpc.private_subnets`:** Worker nodes launch in private subnets only. They cannot be directly accessed from the internet.

**`enable_irsa = true`:** IRSA stands for IAM Roles for Service Accounts. This allows Kubernetes service accounts to assume IAM roles without distributing long-lived AWS credentials. It's used by the Cluster Autoscaler and Load Balancer Controller.

### Managed Node Group

```hcl
eks_managed_node_groups = {
  general = {
    desired_size   = 2
    min_size       = 2
    max_size       = 10
    instance_types = ["t3.large"]
    capacity_type  = "ON_DEMAND"
  }
}
```

This creates an Auto Scaling Group with 2 nodes, scalable up to 10. `t3.large` gives 2 vCPU + 8GB RAM per node. The Cluster Autoscaler (deployed separately) watches pod pending states and triggers scale-out/in within these bounds.

The spot node group is commented out. Spot instances cost 60–80% less but can be reclaimed with 2-minute notice. For fault-tolerant workloads (stateless apps), enabling the spot group makes economic sense.

### aws-auth ConfigMap

```hcl
manage_aws_auth_configmap = true
aws_auth_roles = [
  {
    rolearn  = module.eks_admins_iam_role.iam_role_arn
    username = module.eks_admins_iam_role.iam_role_name
    groups   = ["system:masters"]
  },
]
```

The `aws-auth` ConfigMap in `kube-system` is EKS's way of mapping AWS IAM identities to Kubernetes RBAC. Adding the `eks-admin` role here with `system:masters` (cluster admin) means anyone who assumes that role can do anything in the cluster.

### Kubernetes Provider

```hcl
provider "kubernetes" {
  host                   = data.aws_eks_cluster.default.endpoint
  cluster_ca_certificate = base64decode(...)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", data.aws_eks_cluster.default.id]
    command     = "aws"
  }
}
```

Instead of using a static token, the provider calls `aws eks get-token` every time it needs to authenticate. This is the recommended approach because EKS tokens expire after 15 minutes.

**Important:** This means the AWS CLI must be installed and configured wherever `terraform apply` runs (i.e., on the Jenkins server).

---

## iam.tf — Access Control

This file builds an IAM hierarchy for EKS cluster access. Here's how the pieces connect:

```
user1 (IAM User)
  └── eks-admin (IAM Group)
        └── allow-assume-eks-admin-iam-role (IAM Policy)
              └── eks-admin (IAM Role)  ← also in aws-auth ConfigMap
                    └── allow-eks-access (IAM Policy: eks:DescribeCluster)
```

**Why this pattern (role assumption)?**
Direct access: give users an IAM policy that grants Kubernetes access.
Role assumption (this pattern): users don't have Kubernetes permissions directly — they assume a role that does. This is better because:
- You can revoke access by removing users from the group, not by editing cluster configs.
- You can require MFA for role assumption (`role_requires_mfa = true`).
- You can audit who assumed the role via CloudTrail.

**`user1`:** A placeholder IAM user created without access keys or login profile. In practice, you would add real users here, or replace this with an IAM group mapped to your organization's SSO.

**`trusted_role_arns = ["arn:aws:iam::${module.vpc.vpc_owner_id}:root"]`:** The `:root` principal means any IAM identity in the account can attempt to assume this role, subject to having the `allow-assume-eks-admin-iam-role` policy. This is a common pattern — the role itself restricts what it can do; the policy restricts who can assume it.

---

## autoscaler-iam.tf — Autoscaler Permissions

```hcl
module "cluster_autoscaler_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.3.1"

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

**What it does:** Creates an IAM role that can only be assumed by the `cluster-autoscaler` service account in the `kube-system` namespace. The `attach_cluster_autoscaler_policy = true` flag attaches a pre-built policy that grants permissions to describe and modify Auto Scaling Groups.

**How IRSA works:**
1. EKS runs an OIDC provider (a trust authority).
2. The IAM role's trust policy says: "trust tokens signed by this EKS OIDC provider for service account `kube-system:cluster-autoscaler`".
3. When the autoscaler pod starts, it gets a JWT token via a projected service account volume.
4. The AWS SDK exchanges this JWT for temporary AWS credentials by calling the OIDC provider.

No static credentials are stored anywhere. Access is scoped to exactly one service account.

---

## autoscaler-manifest.tf — Autoscaler Workload

This file deploys the Cluster Autoscaler into the cluster using raw YAML manifests. It creates:

| Resource | Kind | Purpose |
|----------|------|---------|
| `cluster-autoscaler` | ServiceAccount | Kubernetes identity; annotated with the IRSA role ARN |
| `cluster-autoscaler` | Role | Grants access to ConfigMaps in kube-system |
| `cluster-autoscaler` | RoleBinding | Binds the Role to the ServiceAccount |
| `cluster-autoscaler` | ClusterRole | Grants cluster-wide read/write access to node/pod resources |
| `cluster-autoscaler` | ClusterRoleBinding | Binds the ClusterRole to the ServiceAccount |
| `cluster-autoscaler` | Deployment | Runs the autoscaler as a single pod |

**How autoscaling works:**
1. A pod enters `Pending` state because no node has enough free capacity.
2. The autoscaler detects this via the Kubernetes API (using ClusterRole permissions).
3. The autoscaler identifies which Auto Scaling Group can accommodate the pod.
4. It calls the AWS ASG API (using IRSA credentials) to increment `DesiredCapacity`.
5. A new EC2 instance launches, joins the cluster, and the pod is scheduled.
6. If nodes are underutilized for 10 minutes, the autoscaler removes them.

**Known issue — deprecated container image registry:**
```
image: k8s.gcr.io/autoscaling/cluster-autoscaler:v1.23.1
```
`k8s.gcr.io` was retired in March 2023. Images were migrated to `registry.k8s.io`. Also, autoscaler version v1.23.1 is designed for Kubernetes 1.23, but this cluster runs 1.27. The autoscaler version must match the cluster minor version.

**Fix — update `autoscaler-manifest.tf` line 176:**
```hcl
image: registry.k8s.io/autoscaling/cluster-autoscaler:v1.27.8
```

Find the correct tag at: https://github.com/kubernetes/autoscaler/releases

---

## ebs_csi_driver.tf — Block Storage

```hcl
resource "aws_eks_addon" "addons" {
  for_each      = { for addon in var.addons : addon.name => addon }
  cluster_name  = module.eks.cluster_id
  addon_name    = each.value.name
  addon_version = each.value.version
}
```

**What it does:** Iterates the `addons` list from `variables.tf` and creates an EKS managed addon for each entry. This includes the `aws-ebs-csi-driver`.

**Why the EBS CSI driver matters:** By default, EKS clusters have no way to provision persistent storage. Any pod that needs to store data across restarts (like Prometheus) needs a PersistentVolume backed by EBS. The CSI driver is what allows Kubernetes to call `aws ec2 create-volume` when a PersistentVolumeClaim is created.

**Note:** The EBS CSI driver addon requires its own IAM role in a production setup. This project uses the node IAM role's permissions implicitly, which works but is not least-privilege. For strict environments, add an `ebs-csi-controller-sa` IRSA role.

---

## helm-provider.tf — Helm Configuration

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

Same authentication pattern as the Kubernetes provider — uses `aws eks get-token` rather than a static bearer token. This provider manages Helm chart deployments as Terraform resources.

---

## helm-load-balancer-controller.tf — Ingress

```hcl
module "aws_load_balancer_controller_irsa_role" { ... }

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.4.4"
  ...
}
```

**What it does:** Deploys the AWS Load Balancer Controller, which watches for Kubernetes `Ingress` and `Service` resources of type `LoadBalancer` and creates corresponding AWS ALBs and NLBs.

**Without this controller:** Any `Service` of type `LoadBalancer` creates a classic ELB (deprecated). Any `Ingress` resource is ignored (no in-tree AWS ingress controller exists in modern EKS).

**With this controller:** You can create an ALB with a single annotation on your Ingress:
```yaml
metadata:
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
```

**Issue — outdated version:** Chart version 1.4.4 is from late 2022. The current version is 1.6+. Update the `version` field to get security patches and bug fixes. Check the current version at https://github.com/aws/eks-charts.

**IRSA role:** Same pattern as the autoscaler — a dedicated IAM role for the `aws-load-balancer-controller` service account in `kube-system`.

---

## monitoring.tf — Observability

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

**What `time_sleep` does:** After the EKS module reports the cluster as ready, the Kubernetes API may not be fully responsive for a few seconds. The 20-second sleep prevents the subsequent `kubernetes_namespace` from failing with a connection error. This is a workaround for a known race condition.

**What gets deployed:**
The `kube-prometheus-stack` Helm chart installs a complete monitoring stack:

| Component | Function |
|-----------|----------|
| Prometheus | Time-series database; scrapes metrics from all cluster components |
| Alertmanager | Routes alerts from Prometheus to email/Slack/PagerDuty |
| kube-state-metrics | Exposes Kubernetes object state as metrics (pod restarts, deployment replicas, etc.) |
| node-exporter | Exposes OS-level metrics (CPU, memory, disk) from each node |
| Prometheus Operator | Manages Prometheus configuration declaratively via CRDs |

**Issue — Prometheus memory limit is too low:**
```hcl
set {
  name  = "prometheus.server.resources"
  value = yamlencode({
    limits   = { cpu = "200m", memory = "50Mi" }
    requests = { cpu = "100m", memory = "30Mi" }
  })
}
```
50Mi is far too small for Prometheus. It will OOMKill within minutes of starting when it has real cluster metrics to store. A realistic minimum for a small cluster is 512Mi. Increase this before applying.

---

## Jenkinsfile — CI/CD Pipeline

### Stage 1: Fetch Credentials from Vault

```groovy
withCredentials([
    string(credentialsId: 'VAULT_URL',      variable: 'VAULT_URL'),
    string(credentialsId: 'vault-role-id',  variable: 'VAULT_ROLE_ID'),
    string(credentialsId: 'vault-secret-id', variable: 'VAULT_SECRET_ID')
]) {
    sh '''
    VAULT_TOKEN=$(vault write -field=token auth/approle/login \
        role_id=${VAULT_ROLE_ID} secret_id=${VAULT_SECRET_ID})
    export VAULT_TOKEN=$VAULT_TOKEN

    GIT_TOKEN=$(vault kv get -field=pat secret/github)
    AWS_ACCESS_KEY_ID=$(vault kv get -field=aws_access_key_id aws/terraform-project)
    AWS_SECRET_ACCESS_KEY=$(vault kv get -field=aws_secret_access_key aws/terraform-project)

    echo "export GIT_TOKEN=${GIT_TOKEN}" >> vault_env.sh
    echo "export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}" >> vault_env.sh
    echo "export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}" >> vault_env.sh
    '''
}
```

**What happens:** Jenkins pulls three credentials from its own credential store (not Vault). These are used to authenticate to Vault. Once authenticated, Jenkins retrieves the actual secrets (AWS keys, GitHub token) and writes them to `vault_env.sh`, which subsequent stages source.

**Security concern:** This approach writes secrets to a file on disk. The `cleanWs()` in the `post` block deletes the workspace including this file. However, the credentials appear in the Terraform environment, which means they could appear in debug output. The debug `echo` lines in Stage 4 (`echo "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}"`) are a real security risk — remove them.

**AppRole TTL:** The `secret_id` has a 24-hour default TTL. If the pipeline runs after 24 hours have passed since the `secret_id` was generated, login will fail. Automate secret_id rotation or increase the TTL in Vault's AppRole configuration.

### Stage 3: Install Terraform

```sh
wget -q -O terraform.zip https://releases.hashicorp.com/terraform/1.3.4/terraform_1.3.4_linux_amd64.zip
```

**Issue:** Downloads Terraform 1.3.4 on every pipeline run (slow). Consider pre-installing Terraform on the Jenkins server and using the Jenkins Terraform plugin to manage versions, or pin a more recent version (1.6+).

### Stage 4: Terraform Init and Apply

```sh
. ${WORKSPACE}/vault_env.sh
cd aws-eks-terraform
../terraform init
../terraform plan -out=tfplan
../terraform apply -auto-approve tfplan
```

The pipeline sources `vault_env.sh` to load AWS credentials into the shell environment. Terraform picks them up via the standard `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` environment variables.

### Stage 5: Update Kubeconfig

```sh
CLUSTER_NAME=$(aws eks list-clusters --region us-east-1 --query 'clusters[0]' --output text)
aws eks update-kubeconfig --name $CLUSTER_NAME --region us-east-1 \
    --kubeconfig /var/lib/jenkins/.kube/config
```

**Fragile point:** `clusters[0]` returns the first cluster alphabetically. If your account has multiple EKS clusters, this may pick the wrong one. Replace with a direct reference:
```sh
CLUSTER_NAME="${var.cluster_name}"  # or hardcode: demo-eks-cluster
```

### Stage 6 & 7: Destroy (Optional)

The pipeline pauses and prompts the operator before destroying. Selecting "No" marks the build as `SUCCESS` and skips the destroy stage. This prevents accidental teardown when the pipeline is only intended to apply changes.

---

## values.yaml — Prometheus Configuration

The `values.yaml` file overrides Helm chart defaults for the Prometheus stack. Key settings:

| Setting | Value | Meaning |
|---------|-------|---------|
| `rbac.create` | `true` | Creates RBAC resources for Prometheus |
| `alertmanager.enabled` | `true` | Deploys Alertmanager |
| `kube-state-metrics.enabled` | `true` | Deploys kube-state-metrics |
| `prometheus-node-exporter.enabled` | `true` | Deploys node exporter on every node |
| `server.retention` | `15d` | Keeps 15 days of metrics data |
| `server.persistentVolume.enabled` | `true` | Uses EBS for storage |
| `server.persistentVolume.size` | `8Gi` | 8 GB EBS volume |
| `server.service.type` | `ClusterIP` | Not exposed externally (use port-forward to access) |

---

## Code Issues and Required Fixes

### Fix 1 — Update deprecated image registry (autoscaler-manifest.tf:176)

**Current:**
```yaml
image: k8s.gcr.io/autoscaling/cluster-autoscaler:v1.23.1
```
**Fix:**
```yaml
image: registry.k8s.io/autoscaling/cluster-autoscaler:v1.27.8
```
The version must match your EKS cluster minor version (1.27 → autoscaler v1.27.x).

### Fix 2 — Remove credential debug echo (Jenkinsfile:91-92)

**Current:**
```sh
echo "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}"
echo "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}"
```
**Fix:** Delete both lines. Jenkins masks credentials in `withCredentials` blocks, but these credentials come from `vault_env.sh` outside that block, so they will appear in plain text in the build log.

### Fix 3 — Fix Prometheus memory limit (monitoring.tf:47)

**Current:**
```hcl
limits = { cpu = "200m", memory = "50Mi" }
```
**Fix:**
```hcl
limits   = { cpu = "500m", memory = "1Gi" }
requests = { cpu = "200m", memory = "512Mi" }
```

### Fix 4 — Declare kubernetes provider (provider.tf)

Add to `required_providers`:
```hcl
kubernetes = {
  source  = "hashicorp/kubernetes"
  version = ">= 2.10.0"
}
```

### Fix 5 — Change cluster_version type (variables.tf:6)

**Current:** `type = number`
**Fix:** `type = string` and update default to `"1.27"`

---

## Dependency Graph

The order Terraform applies resources (simplified):

```
1. VPC (vpc.tf)
   └── 2. EKS Cluster (eks.tf)
         ├── 3a. aws-auth ConfigMap (eks.tf, via module)
         ├── 3b. IAM Roles (iam.tf, autoscaler-iam.tf, helm-load-balancer-controller.tf)
         ├── 3c. EKS Addons (ebs_csi_driver.tf)
         │
         └── 4. [20s sleep] (monitoring.tf)
               ├── 5a. prometheus namespace (monitoring.tf)
               │     └── 6a. Prometheus Helm release (monitoring.tf)
               ├── 5b. Cluster Autoscaler RBAC + Deployment (autoscaler-manifest.tf)
               └── 5c. AWS Load Balancer Controller Helm release (helm-load-balancer-controller.tf)
```

Resources at the same numbered level can be created in parallel by Terraform.

Terraform destroy runs this graph in reverse — Helm releases and Kubernetes resources are deleted before the EKS cluster, and the EKS cluster before the VPC.
