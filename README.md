# AWS EKS Infrastructure with Terraform, Jenkins CI/CD, and HashiCorp Vault

A production-ready Infrastructure-as-Code (IaC) project that provisions a fully managed AWS EKS cluster, complete with autoscaling, load balancing, monitoring, and a secure Jenkins CI/CD pipeline backed by HashiCorp Vault for secrets management.

---

## What This Project Builds

| Component | Technology | Purpose |
|-----------|-----------|---------|
| Networking | AWS VPC (Terraform module) | Isolated network with public/private subnets |
| Kubernetes | AWS EKS 1.27 | Managed control plane + managed node groups |
| Secrets | HashiCorp Vault (AppRole) | Secure storage of AWS and GitHub credentials |
| CI/CD | Jenkins | Automated pipeline to plan/apply/destroy infra |
| Autoscaling | Cluster Autoscaler | Scale worker nodes based on pod demand |
| Load Balancing | AWS Load Balancer Controller | Kubernetes-native ALB/NLB provisioning |
| Monitoring | Prometheus + Alertmanager | Cluster and application metrics |
| State Backend | S3 + DynamoDB | Remote state with locking |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Developer / Operator                         │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ push code / trigger build
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     Jenkins EC2 Instance                             │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │  Pipeline Stages                                             │    │
│  │  1. Fetch secrets ──► HashiCorp Vault (AppRole auth)         │    │
│  │  2. Clone repo    ──► GitHub (using GIT_TOKEN from Vault)    │    │
│  │  3. tf init       ──► S3 backend (state) + DynamoDB (lock)   │    │
│  │  4. tf plan/apply ──► AWS API (using AWS creds from Vault)   │    │
│  │  5. kubeconfig    ──► EKS cluster endpoint                   │    │
│  │  6. verify        ──► kubectl get nodes / pods               │    │
│  │  7. [optional] tf destroy                                    │    │
│  └──────────────────────────────────────────────────────────────┘    │
└──────────────────────────┬──────────────────────────────────────────┘
                           │ terraform apply
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│                          AWS Cloud (us-east-1)                      │
│                                                                     │
│  ┌─────────────────── VPC 10.0.0.0/16 ──────────────────────────┐   │
│  │                                                              │   │
│  │   Public Subnets (us-east-1a/1b)   Private Subnets           │   │
│  │   10.0.64.0/19  10.0.96.0/19       10.0.0.0/19  10.0.32.0/19 │   │
│  │         │                                  │                 │   │
│  │         │                                  │                 │   │
│  │   ┌─────┴──────┐                    ┌──────┴──────────┐      │   │
│  │   │  NAT GW    │                    │   EKS Managed   │      │   │
│  │   │  (single)  │◄───────────────────│   Node Group    │      │   │
│  │   └─────┬──────┘    outbound        │  (t3.large x2+) │      │   │
│  │         │           traffic         └──────┬──────────┘      │   │
│  │   ┌─────┴──────┐                           │                 │   │
│  │   │  Internet  │                    ┌──────┴──────────┐      │   │
│  │   │  Gateway   │                    │  EKS Control    │      │   │
│  │   └────────────┘                    │  Plane (managed)│      │   │
│  │                                     └─────────────────┘      │   │
│  └──────────────────────────────────────────────────────────────-   │
│                                                                     │
│  Workloads running on EKS nodes (kube-system namespace):            │
│  ┌──────────────────┐  ┌────────────────────┐  ┌────────────────┐   │
│  │ Cluster          │  │ AWS Load Balancer  │  │  Prometheus +  │   │
│  │ Autoscaler       │  │ Controller         │  │  Alertmanager  │   │
│  │ (IRSA role)      │  │ (IRSA role)        │  │  (Helm)        │   │
│  └──────────────────┘  └────────────────────┘  └────────────────┘   │
│                                                                     │
│  EKS Add-ons (managed):                                             │
│  kube-proxy  |  vpc-cni  |  coredns  |  aws-ebs-csi-driver          │
│                                                                     │
│  IAM Resources:                                                     │
│  ┌───────────────┐  ┌─────────────────┐  ┌───────────────────────┐  │
│  │ eks-admin     │  │ allow-eks-access │  │ eks-admin IAM Group  │  │
│  │ IAM Role      │  │ IAM Policy      │  │ (user1 member)        │  │
│  └───────────────┘  └─────────────────┘  └───────────────────────┘  │
│                                                                     │
│  State Backend:                                                     │
│  ┌─────────────────────────────┐  ┌──────────────────────────────┐  │
│  │ S3 Bucket                   │  │ DynamoDB Table               │  │
│  │ devops-projects-terraform-  │  │ terraform-state-lock         │  │
│  │ backends / eks/terraform... │  │ (prevents concurrent apply)  │  │
│  └─────────────────────────────┘  └──────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                   HashiCorp Vault Server                            │
│                                                                     │
│  Secrets:                                                           │
│  aws/terraform-project  →  aws_access_key_id, aws_secret_access_key │
│  secret/github          →  pat (GitHub Personal Access Token)       │
│                                                                     │
│  Auth method: AppRole                                               │
│  Credentials stored in Jenkins: vault-role-id, vault-secret-id,     │
│                                  VAULT_URL                          │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Implementation Order

Follow these phases in sequence. Each phase depends on the previous one.

### Phase 0 — Prerequisites (Manual, One-Time Setup)

Before running any Terraform or Jenkins pipeline, set up the supporting infrastructure manually.

**Step 0.1 — AWS Account Setup**
- Create or log in to an AWS account.
- Create an IAM user (or role) with these managed policies attached:
  - `AmazonEKSFullAccess`
  - `AmazonEC2FullAccess`
  - `IAMFullAccess`
  - `AmazonS3FullAccess` (for the Terraform state bucket)
  - `AmazonDynamoDBFullAccess` (for the state lock table)
- Generate and save an **Access Key ID** and **Secret Access Key** for this user.

**Step 0.2 — Terraform State Backend Setup**
Before any `terraform init`, the S3 bucket and DynamoDB table must exist:

```bash
# Create S3 bucket (match the name in backend.tf)
aws s3api create-bucket \
  --bucket devops-projects-terraform-backends \
  --region us-east-1

# Enable versioning on the bucket
aws s3api put-bucket-versioning \
  --bucket devops-projects-terraform-backends \
  --versioning-configuration Status=Enabled

# Create DynamoDB table for state locking
aws dynamodb create-table \
  --table-name terraform-state-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

**Step 0.3 — EC2 Instance for Jenkins**
- Launch an EC2 instance (Ubuntu 22.04 recommended, t3.medium minimum).
- Install Jenkins:
  ```bash
  sudo apt update && sudo apt install -y openjdk-17-jdk
  curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | sudo gpg --dearmor -o /usr/share/keyrings/jenkins-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.gpg] https://pkg.jenkins.io/debian-stable binary/" | sudo tee /etc/apt/sources.list.d/jenkins.list
  sudo apt update && sudo apt install -y jenkins
  sudo systemctl enable jenkins && sudo systemctl start jenkins
  ```
- Install kubectl on the Jenkins server:
  ```bash
  curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  ```
- Install AWS CLI:
  ```bash
  curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
  unzip awscliv2.zip && sudo ./aws/install
  ```
- Install required Jenkins plugins via Manage Jenkins > Plugins:
  - Pipeline
  - Terraform
  - HashiCorp Vault
  - AWS Credentials
  - Git

**Step 0.4 — HashiCorp Vault Server Setup**
- Launch a separate EC2 instance for Vault (or use an existing server).
- Install and initialize Vault:
  ```bash
  wget https://releases.hashicorp.com/vault/1.15.0/vault_1.15.0_linux_amd64.zip
  unzip vault_1.15.0_linux_amd64.zip && sudo mv vault /usr/local/bin/
  vault server -dev  # for dev/testing only; use production config for real deployments
  ```
- Store secrets:
  ```bash
  export VAULT_ADDR='http://<vault-server-ip>:8200'
  vault login <root-token>

  # Store AWS credentials
  vault kv put aws/terraform-project \
    aws_access_key_id=<YOUR_ACCESS_KEY> \
    aws_secret_access_key=<YOUR_SECRET_KEY>

  # Store GitHub PAT
  vault kv put secret/github pat=<YOUR_GITHUB_PAT>
  ```
- Enable AppRole auth and create a role:
  ```bash
  vault auth enable approle
  vault write auth/approle/role/jenkins-role \
    secret_id_ttl=24h \
    token_ttl=1h \
    token_policies="default,jenkins-policy"

  # Get role_id and secret_id
  vault read auth/approle/role/jenkins-role/role-id
  vault write -f auth/approle/role/jenkins-role/secret-id
  ```

**Step 0.5 — Configure Jenkins Credentials**
In Jenkins > Manage Jenkins > Credentials, add three Secret Text credentials:
- `VAULT_URL` — the full URL of your Vault server (e.g., `http://1.2.3.4:8200`)
- `vault-role-id` — the AppRole role ID from Step 0.4
- `vault-secret-id` — the AppRole secret ID from Step 0.4

---

### Phase 1 — Customize Terraform Configuration

**Step 1.1 — Update `backend.tf`**
Replace the S3 bucket name with your own bucket (created in Step 0.2):
```hcl
terraform {
  backend "s3" {
    bucket         = "YOUR-BUCKET-NAME"   # change this
    key            = "eks/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-lock"
  }
}
```

**Step 1.2 — Review and Update `variables.tf`**
Adjust defaults to match your environment:
```hcl
variable "cluster_name"       { default = "my-eks-cluster" }     # rename as needed
variable "cluster_version"    { default = 1.27 }                  # update if newer version needed
variable "region"             { default = "us-east-1" }           # your preferred region
variable "availability_zones" { default = ["us-east-1a", "us-east-1b"] }
```

**Step 1.3 — Review `Jenkinsfile`**
- Update the GitHub repo URL in the `Checkout Source Code` stage if you forked this repo.
- Remove or mask the debug `echo` lines that print AWS credentials (security best practice).

---

### Phase 2 — Run the Jenkins Pipeline

**Step 2.1 — Create Jenkins Pipeline Job**
- New Item > Pipeline
- In Pipeline Definition, choose "Pipeline script from SCM"
- Set your GitHub repo URL and credentials (using the GIT_TOKEN from Vault)
- Jenkinsfile path: `Jenkinsfile`

**Step 2.2 — Trigger the Pipeline**
The pipeline executes these stages in order:

| Stage | What Happens |
|-------|-------------|
| Fetch Credentials from Vault | Jenkins authenticates to Vault via AppRole; retrieves AWS keys and GitHub PAT; writes them to `vault_env.sh` |
| Checkout Source Code | Clones this repo using the GitHub PAT |
| Install Terraform | Downloads Terraform 1.3.4 binary into the workspace |
| Terraform Init | Runs `terraform init` — downloads providers and connects to the S3/DynamoDB backend |
| Terraform Plan and Apply | Runs `terraform plan` then `terraform apply -auto-approve` — provisions all AWS resources |
| Update Kubeconfig and Verify | Updates Jenkins user's kubeconfig; runs `kubectl get nodes` to confirm connectivity |
| Prompt for Terraform Destroy | Pauses pipeline for manual confirmation before destroying anything |
| Terraform Destroy (optional) | If confirmed, tears down all provisioned resources |

**Step 2.3 — Monitor the Apply**
EKS provisioning takes 12–20 minutes. Watch the Jenkins console output. The pipeline will fail fast if:
- Vault credentials are wrong (Stage 1)
- AWS permissions are insufficient (Stage 4)
- The S3 bucket or DynamoDB table doesn't exist (Stage 4, init)

---

### Phase 3 — Verify the Infrastructure

**Step 3.1 — AWS Console Checks**
- EKS > Clusters: confirm `demo-eks-cluster` is Active
- EC2 > Auto Scaling Groups: confirm the node group ASG exists with 2 instances
- VPC > Your VPCs: confirm the `main` VPC with 4 subnets

**Step 3.2 — Kubernetes Connectivity**
Configure your local kubeconfig (if accessing from outside Jenkins):
```bash
aws eks update-kubeconfig --name demo-eks-cluster --region us-east-1
```

Verify the cluster:
```bash
kubectl get nodes                          # should show 2 t3.large nodes
kubectl get pods --all-namespaces          # should show system pods running
kubectl get pods -n kube-system            # cluster-autoscaler, LBC, coredns, etc.
kubectl get pods -n prometheus             # prometheus and alertmanager pods
```

**Step 3.3 — Verify Add-ons**
```bash
aws eks list-addons --cluster-name demo-eks-cluster
# Expected: kube-proxy, vpc-cni, coredns, aws-ebs-csi-driver
```

**Step 3.4 — Verify Monitoring**
```bash
kubectl get svc -n prometheus
# Port-forward to access Prometheus UI locally:
kubectl port-forward svc/prometheus-server 9090:80 -n prometheus
# Open http://localhost:9090 in your browser
```

---

### Phase 4 — Teardown (When Done)

Use the Jenkins pipeline's "Prompt for Terraform Destroy" stage, or run manually:
```bash
aws eks update-kubeconfig --name demo-eks-cluster --region us-east-1
terraform destroy -auto-approve
```

> **Order matters on destroy**: Helm releases and Kubernetes resources must be deleted before the EKS cluster, and the EKS cluster before the VPC. Terraform handles this automatically via dependency tracking as long as all resources were created by Terraform.

---

## Known Issues and Things to Customize Before Use

| File | Issue | Action Required |
|------|-------|----------------|
| `backend.tf` | Hardcoded S3 bucket name | Change to your own bucket |
| `autoscaler-manifest.tf:176` | Image `k8s.gcr.io` registry is deprecated; v1.23.1 doesn't match EKS 1.27 | Change to `registry.k8s.io/autoscaling/cluster-autoscaler:v1.27.x` |
| `Jenkinsfile:91,92` | Prints AWS credentials to build log | Remove those `echo` debug lines |
| `Jenkinsfile:61` | Hardcoded GitHub repo URL | Update to your fork's URL |
| `monitoring.tf:47` | Prometheus memory limit is 50Mi (too low) | Increase to at least 512Mi |
| `variables.tf:7` | EKS 1.27 is approaching end-of-life | Consider upgrading to 1.29 or 1.30 |
| `provider.tf` | Missing `kubernetes` in `required_providers` | See `IMPLEMENTATION_GUIDE.md` for fix |

---

## Cost Estimate

Running this stack continuously in us-east-1:

| Resource | Approximate Monthly Cost |
|----------|--------------------------|
| EKS Control Plane | ~$73 |
| 2x t3.large nodes (On-Demand) | ~$120 |
| NAT Gateway | ~$32 |
| S3 + DynamoDB (state) | ~$1 |
| **Total** | **~$226/month** |

Use `terraform destroy` when not actively testing to avoid unnecessary charges.

---

## File Reference

| File | Role |
|------|------|
| `provider.tf` | AWS, kubectl, and Helm provider declarations |
| `backend.tf` | S3 remote state backend with DynamoDB locking |
| `variables.tf` | Configurable inputs (cluster name, region, addons) |
| `vpc.tf` | VPC, public/private subnets, NAT gateway |
| `eks.tf` | EKS cluster, node groups, aws-auth configmap, Kubernetes provider |
| `iam.tf` | IAM roles, policies, user, and group for cluster access |
| `autoscaler-iam.tf` | IRSA role for Cluster Autoscaler |
| `autoscaler-manifest.tf` | Kubernetes RBAC + Deployment for Cluster Autoscaler |
| `ebs_csi_driver.tf` | EBS CSI driver EKS managed addon |
| `helm-provider.tf` | Helm provider pointing at the EKS cluster |
| `helm-load-balancer-controller.tf` | AWS Load Balancer Controller via Helm |
| `monitoring.tf` | Prometheus + Alertmanager stack via Helm |
| `values.yaml` | Helm values for the Prometheus stack |
| `Jenkinsfile` | Jenkins declarative pipeline definition |
