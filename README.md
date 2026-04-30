# AWS EKS Infrastructure with Terraform, Jenkins CI/CD, and HashiCorp Vault

Provisions a fully managed AWS EKS cluster using Terraform, automated through a Jenkins CI/CD pipeline, with AWS and GitHub credentials securely managed by HashiCorp Vault.

---

## What This Project Builds

| Component | Technology | Purpose |
|-----------|-----------|---------|
| Networking | AWS VPC | Isolated network with public/private subnets |
| Kubernetes | AWS EKS 1.32 | Managed control plane + managed node groups |
| Secrets | HashiCorp Vault (AppRole) | Secure storage of AWS and GitHub credentials |
| CI/CD | Jenkins | Automated pipeline to provision or destroy infra |
| Autoscaling | Cluster Autoscaler | Scales worker nodes based on pod demand |
| Load Balancing | AWS Load Balancer Controller | Kubernetes-native ALB/NLB provisioning |
| Monitoring | Prometheus + Alertmanager | Cluster and application metrics |
| State Backend | S3 + DynamoDB | Remote Terraform state with locking |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Developer / Operator                         │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ Build with Parameters (Apply/Destroy)
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     Jenkins EC2 Instance                            │
│                                                                     │
│  Pipeline Stages (Apply):                                           │
│  1. Fetch secrets  ──► HashiCorp Vault (AppRole auth)               │
│  2. Clone repo     ──► GitHub                                       │
│  3. tf init        ──► S3 backend + DynamoDB lock                   │
│  4. tf plan/apply  ──► AWS API                                      │
│  5. kubeconfig     ──► EKS cluster endpoint                         │
│  6. verify         ──► kubectl get nodes / pods                     │
│                                                                     │
│  Pipeline Stages (Destroy):                                         │
│  1. Fetch secrets  ──► HashiCorp Vault                              │
│  2. Clone repo     ──► GitHub                                       │
│  3. tf init        ──► S3 backend                                   │
│  4. tf destroy     ──► AWS API                                      │
└──────────────────────────┬──────────────────────────────────────────┘
                           │ terraform apply
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│                       AWS Cloud (us-east-1)                         │
│                                                                     │
│  ┌──────────────────── VPC 10.0.0.0/16 ─────────────────────────┐   │
│  │  Public Subnets          │  Private Subnets                   │   │
│  │  10.0.64.0/19            │  10.0.0.0/19                       │   │
│  │  10.0.96.0/19            │  10.0.32.0/19                      │   │
│  │         │                         │                           │   │
│  │   ┌─────┴──────┐          ┌───────┴─────────┐                 │   │
│  │   │  NAT GW    │◄─────────│  EKS Nodes      │                 │   │
│  │   │  Internet  │ outbound │  (t3.large x2+) │                 │   │
│  │   │  Gateway   │ traffic  │                 │                 │   │
│  │   └────────────┘          └───────┬─────────┘                 │   │
│  │                           ┌───────┴─────────┐                 │   │
│  │                           │  EKS Control    │                 │   │
│  │                           │  Plane (managed)│                 │   │
│  │                           └─────────────────┘                 │   │
│  └───────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  Workloads on EKS:                                                  │
│  Cluster Autoscaler | AWS Load Balancer Controller | Prometheus     │
│                                                                     │
│  EKS Managed Add-ons:                                               │
│  kube-proxy | vpc-cni | coredns | aws-ebs-csi-driver               │
│                                                                     │
│  State Backend:                                                     │
│  S3 Bucket (terraform state) + DynamoDB Table (state lock)          │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                   HashiCorp Vault Server (separate EC2)             │
│                                                                     │
│  Secrets:                                                           │
│  aws/terraform-project  →  aws_access_key_id, aws_secret_access_key │
│  secret/github          →  pat (GitHub Personal Access Token)       │
│                                                                     │
│  Auth: AppRole  |  Port: 8200                                       │
│  Jenkins stores only: VAULT_URL, vault-role-id, vault-secret-id     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Server Setup Overview

You need **two EC2 instances** before running the pipeline:

| Server | Purpose | Minimum Size |
|--------|---------|-------------|
| Jenkins Server | Runs the CI/CD pipeline | t3.medium |
| Vault Server | Stores secrets securely | t2.micro |

Both must be in the same VPC so they can communicate via private IP.

---

## Step-by-Step Implementation

### Step 1 — AWS Prerequisites

**1.1 — Create IAM user for Terraform** with these policies:
- `AmazonEKSFullAccess`
- `AmazonEC2FullAccess`
- `IAMFullAccess`
- `AmazonS3FullAccess`
- `AmazonDynamoDBFullAccess`

Save the **Access Key ID** and **Secret Access Key** — you will store these in Vault later.

**1.2 — Create Terraform state backend resources**

Run these from your local machine or AWS CLI:

```bash
# Create S3 bucket — change the name to something unique to your account
aws s3api create-bucket --bucket YOUR-BUCKET-NAME --region us-east-1

aws s3api put-bucket-versioning \
  --bucket YOUR-BUCKET-NAME \
  --versioning-configuration Status=Enabled

# Create DynamoDB table for state locking
aws dynamodb create-table \
  --table-name terraform-state-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

Then update `backend.tf` with your bucket name:
```hcl
bucket = "YOUR-BUCKET-NAME"
```

---

### Step 2 — Vault Server Setup

SSH into your **Vault EC2 instance** and run all of the following.

**2.1 — Install Vault**

```bash
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com jammy main" | sudo tee /etc/apt/sources.list.d/hashicorp.list

sudo apt update && sudo apt install -y vault
which vault
```

**2.2 — Run Vault as a systemd service**

> Important: do NOT run `vault server -dev &` as a background process. It dies when your SSH session ends. Use systemd so it stays running permanently.

```bash
sudo tee /etc/systemd/system/vault.service > /dev/null << 'EOF'
[Unit]
Description=HashiCorp Vault Dev Server
After=network.target

[Service]
User=ubuntu
ExecStart=/usr/bin/vault server -dev -dev-listen-address=0.0.0.0:8200 -dev-root-token-id=root
Restart=on-failure
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
```

> If Vault is installed at a different path, find it with `which vault` and update `ExecStart` accordingly.

```bash
sudo systemctl daemon-reload
sudo systemctl enable vault
sudo systemctl start vault
sudo systemctl status vault
```

**2.3 — Configure Vault**

```bash
export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="root"

# Verify Vault is responding
vault status

# Enable AppRole authentication
vault auth enable approle

# Enable KV secrets engine at aws/ path
vault secrets enable -path=aws kv

# Write the access policy to a file (avoids heredoc issues)
cat > /tmp/jenkins-policy.hcl << 'EOF'
path "aws/terraform-project" { capabilities = ["read"] }
path "secret/data/github" { capabilities = ["read"] }
EOF

vault policy write jenkins-policy /tmp/jenkins-policy.hcl

# Create the AppRole
vault write auth/approle/role/jenkins-role token_policies="jenkins-policy" secret_id_ttl=0 token_ttl=1h

# Store your secrets (replace with real values)
vault kv put aws/terraform-project aws_access_key_id="YOUR_AWS_KEY" aws_secret_access_key="YOUR_AWS_SECRET"
vault kv put secret/github pat="YOUR_GITHUB_PAT"

# Get the credentials Jenkins will use
vault read auth/approle/role/jenkins-role/role-id
vault write -f auth/approle/role/jenkins-role/secret-id
```

Save the `role_id` and `secret_id` output — you need them in Step 4.

**2.4 — Open port 8200 in the Vault server's Security Group**

In AWS Console > EC2 > Security Groups > Vault server's SG > Inbound Rules, add:
- Type: Custom TCP
- Port: 8200
- Source: the Jenkins server's private IP (e.g., `172.31.x.x/32`) or the VPC CIDR (`172.31.0.0/16`)

**2.5 — Test connectivity from the Vault server**

```bash
curl http://127.0.0.1:8200/v1/sys/health
```

Should return JSON with `"initialized": true`.

> **Important:** Vault dev mode stores everything in memory. Every time Vault restarts, all secrets and configuration are wiped. Re-run Step 2.3 after any restart. See `hashicorp-vault-explained.md` for a full explanation.

---

### Step 3 — Jenkins Server Setup

SSH into your **Jenkins EC2 instance** and run all of the following.

**3.1 — Install Java and Jenkins**

```bash
sudo apt update && sudo apt install -y openjdk-17-jdk

curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | sudo gpg --dearmor -o /usr/share/keyrings/jenkins-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.gpg] https://pkg.jenkins.io/debian-stable binary/" | sudo tee /etc/apt/sources.list.d/jenkins.list

sudo apt update && sudo apt install -y jenkins
sudo systemctl enable jenkins && sudo systemctl start jenkins
```

**3.2 — Install required tools on the Jenkins server**

```bash
# AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Vault CLI (Jenkins needs this to run vault commands in the pipeline)
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com jammy main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y vault

# Verify all tools are accessible
aws --version
kubectl version --client
vault --version
```

**3.3 — Install Jenkins plugins**

Go to **Manage Jenkins > Plugins > Available plugins** and install:

| Search For | Plugin Name | Notes |
|-----------|------------|-------|
| `Pipeline` | **Pipeline** | Published by Jenkins — installs the full pipeline suite |
| `Vault` | **HashiCorp Vault** | For Vault integration |
| `AWS Credentials` | **AWS Credentials** | For AWS credential storage |
| `Git` | **Git** | For SCM checkout |
| `Terraform` | **Terraform** | For Terraform build steps |

> Do not install "Build Pipeline" — that is a different, older plugin.

**3.4 — Add Jenkins credentials**

Go to **Manage Jenkins > Credentials > Global > Add Credentials**.

Add three credentials of type **Secret Text**:

| Credential ID | Value |
|--------------|-------|
| `VAULT_URL` | `http://<vault-server-private-ip>:8200` |
| `vault-role-id` | the role_id from Step 2.3 |
| `vault-secret-id` | the secret_id from Step 2.3 |

> Use the **private IP** of the Vault server (e.g., `172.31.x.x`), not the public IP or `localhost`. Both servers are in the same VPC so internal communication is free and reliable.

---

### Step 4 — Customize Terraform Files

**4.1 — Update `backend.tf`**
```hcl
terraform {
  backend "s3" {
    bucket         = "YOUR-BUCKET-NAME"   # must match what you created in Step 1.2
    key            = "eks/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-lock"
  }
}
```

**4.2 — Update `variables.tf`** (optional — change defaults to suit your needs)
```hcl
variable "cluster_name"    { default = "demo-eks-cluster" }
variable "cluster_version" { default = "1.32" }
variable "region"          { default = "us-east-1" }
```

**4.3 — Update the repo URL in `Jenkinsfile`**

In the `Checkout Source Code` stage, ensure the URL matches your fork:
```groovy
git clone https://github.com/YOUR-USERNAME/YOUR-REPO.git
```

---

### Step 5 — Create and Run the Jenkins Pipeline

**5.1 — Create a new pipeline job**

- Jenkins Dashboard > New Item > **Pipeline**
- Under **Pipeline Definition**: select **Pipeline script from SCM**
- SCM: **Git**
- Repository URL: `https://github.com/YOUR-USERNAME/YOUR-REPO.git`
- Credentials: **- none -** (the repo is public — no credentials needed here)
- Branch: `*/main`
- Script Path: `Jenkinsfile`
- Save

**5.2 — Run the pipeline**

Click **Build with Parameters**. You will see a dropdown:

| Choice | What It Does |
|--------|-------------|
| `Apply` | Provisions all infrastructure (VPC, EKS, monitoring, autoscaler, LBC) |
| `Destroy` | Tears down all provisioned infrastructure |

Select **Apply** and click Build.

**5.3 — Pipeline stages (Apply)**

| Stage | Duration | What Happens |
|-------|---------|-------------|
| Fetch Credentials from Vault | ~10s | Logs into Vault via AppRole; retrieves AWS keys and GitHub PAT |
| Checkout Source Code | ~10s | Clones the repo |
| Install Terraform | ~30s | Downloads Terraform binary |
| Terraform Init | ~1min | Downloads providers; connects to S3 backend |
| Terraform Plan and Apply | ~15–20min | Provisions VPC, EKS, IAM, autoscaler, LBC, Prometheus |
| Update Kubeconfig and Verify | ~1min | Configures kubectl; verifies nodes and pods |

**5.4 — To destroy infrastructure**

Click **Build with Parameters** > select **Destroy** > Build.

The pipeline will run `terraform destroy -auto-approve` — no blocking prompt, no hanging.

---

### Step 6 — Verify the Infrastructure

```bash
# Configure local kubectl access
aws eks update-kubeconfig --name demo-eks-cluster --region us-east-1

# Verify nodes (expect 2 t3.large nodes)
kubectl get nodes

# Verify system pods
kubectl get pods --all-namespaces

# Verify EKS managed addons
aws eks list-addons --cluster-name demo-eks-cluster

# Access Prometheus UI (port-forward)
kubectl port-forward svc/prometheus-server 9090:80 -n prometheus
# Open http://localhost:9090
```

---

## Common Issues and Fixes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `vault: not found` in pipeline | Vault CLI not installed on Jenkins server | Install vault on Jenkins server (Step 3.2) |
| `connection refused` to Vault | Vault process not running or bound to wrong address | Check systemd service; ensure `0.0.0.0:8200` binding |
| `dial tcp 127.0.0.1:8200` | `VAULT_URL` set to localhost in Jenkins | Update credential to Vault server's private IP |
| `403 permission denied` on AppRole login | Wrong role_id/secret_id or AppRole not enabled | Re-run Vault configuration (Step 2.3) |
| `403` on `secret/github` read | Policy path wrong — KV v2 needs `/data/` | Use `secret/data/github` in policy (not `secret/github`) |
| Vault config wiped after restart | Dev mode stores in memory | Re-run Step 2.3 after every Vault restart |
| `Blocks of type "kubernetes" are not expected` | Helm provider v3.x installed | Pin to `~> 2.6` in `provider.tf` |
| Pipeline hangs after provisioning | Old destroy prompt was a blocking `input()` | Updated — now uses `ACTION` parameter selected before run |
| `cd aws-eks-terraform: No such file` | Wrong directory name in Jenkinsfile | Directory is `terraform-aws-eks-hashicorp-vault` |
| `address already in use` on port 8200 | Old Vault process still running | `sudo kill $(sudo lsof -ti :8200)` then restart service |

---

## Cost Estimate (us-east-1)

| Resource | Approximate Monthly Cost |
|----------|--------------------------|
| EKS Control Plane | ~$73 |
| 2x t3.large nodes | ~$120 |
| NAT Gateway | ~$32 |
| S3 + DynamoDB | ~$1 |
| **Total** | **~$226/month** |

Run the **Destroy** pipeline when not actively using the cluster to avoid charges.

---

## File Reference

| File | Purpose |
|------|---------|
| `provider.tf` | AWS, kubectl, Helm, Kubernetes provider declarations |
| `backend.tf` | S3 remote state + DynamoDB locking |
| `variables.tf` | Cluster name, version, region, addon versions |
| `vpc.tf` | VPC, public/private subnets, NAT gateway |
| `eks.tf` | EKS cluster, managed node groups, aws-auth ConfigMap |
| `iam.tf` | IAM roles, policies, user and group for cluster access |
| `autoscaler-iam.tf` | IRSA role for Cluster Autoscaler |
| `autoscaler-manifest.tf` | Kubernetes RBAC + Deployment for Cluster Autoscaler |
| `ebs_csi_driver.tf` | EBS CSI driver managed addon |
| `helm-provider.tf` | Helm provider configuration |
| `helm-load-balancer-controller.tf` | AWS Load Balancer Controller via Helm |
| `monitoring.tf` | Prometheus + Alertmanager via Helm |
| `values.yaml` | Prometheus Helm chart values |
| `Jenkinsfile` | Jenkins declarative pipeline (Apply/Destroy) |
| `IMPLEMENTATION_GUIDE.md` | Deep explanation of every file and design decision |
| `hashicorp-vault-explained.md` | HashiCorp Vault explained from scratch |
