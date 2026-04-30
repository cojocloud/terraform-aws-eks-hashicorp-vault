# HashiCorp Vault Explained — From Zero to Pipeline Integration

This document explains HashiCorp Vault in plain language, covering what it is, why we use it, how to install and configure it, and exactly how it fits into the Jenkins pipeline in this project.

---

## Table of Contents

1. [What is HashiCorp Vault?](#1-what-is-hashicorp-vault)
2. [Why Use Vault Instead of Just Storing Secrets in Jenkins?](#2-why-use-vault-instead-of-just-storing-secrets-in-jenkins)
3. [Core Concepts You Must Understand](#3-core-concepts-you-must-understand)
4. [Installation](#4-installation)
5. [Starting Vault — Dev Mode vs Production Mode](#5-starting-vault--dev-mode-vs-production-mode)
6. [Vault's Internal Structure — How Secrets are Organized](#6-vaults-internal-structure--how-secrets-are-organized)
7. [KV Secrets Engine — Storing Your First Secret](#7-kv-secrets-engine--storing-your-first-secret)
8. [Authentication — How Clients Prove Their Identity](#8-authentication--how-clients-prove-their-identity)
9. [AppRole — The Authentication Method Used in This Project](#9-approle--the-authentication-method-used-in-this-project)
10. [Policies — Controlling What Each Client Can Access](#10-policies--controlling-what-each-client-can-access)
11. [Full Setup — Step by Step for This Project](#11-full-setup--step-by-step-for-this-project)
12. [How the Jenkins Pipeline Uses Vault](#12-how-the-jenkins-pipeline-uses-vault)
13. [What Happens When Vault Restarts](#13-what-happens-when-vault-restarts)
14. [Common Errors and What They Mean](#14-common-errors-and-what-they-mean)
15. [Dev Mode vs Production — Key Differences](#15-dev-mode-vs-production--key-differences)

---

## 1. What is HashiCorp Vault?

Vault is a tool for **storing and accessing secrets securely**. A secret is anything sensitive — passwords, API keys, database credentials, SSH keys, certificates, AWS access keys.

Think of Vault as a **highly secure safe** that:
- Stores your secrets encrypted
- Controls exactly who can read what
- Logs every access (audit trail)
- Can automatically rotate secrets
- Issues short-lived credentials instead of permanent ones

Without Vault, secrets typically end up:
- Hardcoded in source code (dangerous — anyone who reads the code sees the secret)
- Stored in environment variables on servers (dangerous — visible to anyone with server access)
- Stored in CI/CD tools like Jenkins (better, but still a single point of failure)

With Vault, secrets live in one secure place and nothing else stores them permanently.

---

## 2. Why Use Vault Instead of Just Storing Secrets in Jenkins?

Jenkins has a built-in credential store. Why not just use that?

| | Jenkins Credential Store | HashiCorp Vault |
|--|--------------------------|-----------------|
| Encryption | Basic | AES-256, transit encryption |
| Access control | Per-job or global | Fine-grained policies per path |
| Audit log | Limited | Full audit trail of every read |
| Secret rotation | Manual | Automated |
| Used by multiple tools | No (Jenkins only) | Yes (any app, any language) |
| Dynamic secrets | No | Yes (generate on-demand) |

In this project, Vault holds the **AWS credentials** and **GitHub token**. Jenkins only holds three things: the Vault URL and the AppRole credentials to log into Vault. The actual sensitive secrets never live in Jenkins.

---

## 3. Core Concepts You Must Understand

Before doing anything with Vault, understand these five concepts:

### 3.1 Secrets Engine
A plugin that Vault uses to store or generate secrets. Think of it as a "type" of secret storage.

- **KV (Key-Value)** — stores static secrets like passwords and API keys. This is what we use.
- **AWS** — dynamically generates AWS credentials on demand (more advanced)
- **Database** — generates database passwords on demand
- **PKI** — generates TLS certificates

Each secrets engine is mounted at a path. In this project:
- `aws/` — a KV engine where we store AWS credentials
- `secret/` — the default KV engine in dev mode where we store the GitHub token

### 3.2 Path
Everything in Vault is accessed via a path, like a URL. The path determines where a secret lives.

```
secret/github              ← the path
├── pat = "ghp_abc123"    ← a field (key=value)
```

The path has two parts:
- `secret/` — the mount point (which secrets engine to use)
- `github` — the name of the secret within that engine

### 3.3 Auth Method
How a client (Jenkins, a human, an app) proves its identity to Vault. Vault supports many auth methods:
- **Token** — direct token (root token used for admin tasks)
- **AppRole** — role ID + secret ID (used by machines/pipelines — this is what we use)
- **GitHub** — GitHub personal access token
- **AWS IAM** — AWS identity
- **LDAP** — corporate directory

### 3.4 Token
After successfully authenticating, Vault issues a **token**. Every subsequent request to Vault must include this token. Tokens have a TTL (time-to-live) — they expire after a set time.

### 3.5 Policy
A document that defines what paths a token can access and what it can do (read, write, delete, list). Without a policy granting access, everything is denied by default.

---

## 4. Installation

### On Ubuntu (the method used in this project)

```bash
# Step 1 — Add HashiCorp's GPG key so apt can verify the package
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor \
  -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

# Step 2 — Add HashiCorp's apt repository
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com jammy main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list

# Step 3 — Install Vault
sudo apt update && sudo apt install -y vault

# Step 4 — Verify installation
vault --version
```

**Why install Vault CLI on the Jenkins server too?**

The Vault binary serves two roles:
1. **Server mode** — runs the actual Vault server (on the Vault EC2 instance)
2. **Client mode** — a CLI tool that talks to a Vault server (needed on the Jenkins server so the pipeline can run `vault write` and `vault kv get` commands)

The Jenkins server does NOT run a Vault server — it just uses the Vault CLI as a client to talk to the Vault server.

---

## 5. Starting Vault — Dev Mode vs Production Mode

### Dev Mode (used in this project for learning)

```bash
vault server -dev -dev-listen-address="0.0.0.0:8200" -dev-root-token-id=root
```

What dev mode does automatically:
- Starts Vault already initialized and unsealed (ready to use immediately)
- Creates a root token with the value `root`
- Mounts a KV v2 engine at `secret/`
- Stores everything in memory (lost on restart)
- Listens on port 8200

**Dev mode is only for learning and testing — never use it in production.**

### Running as a systemd service (so it survives reboots)

```bash
# Create the service file
sudo tee /etc/systemd/system/vault.service > /dev/null << 'EOF'
[Unit]
Description=HashiCorp Vault Dev Server
After=network.target

[Service]
User=ubuntu
ExecStart=/usr/local/bin/vault server -dev -dev-listen-address=0.0.0.0:8200 -dev-root-token-id=root
Restart=on-failure
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable vault
sudo systemctl start vault
```

View logs:
```bash
journalctl -u vault -f
```

### Before any Vault CLI command, set these environment variables

```bash
export VAULT_ADDR="http://127.0.0.1:8200"   # where Vault is running
export VAULT_TOKEN="root"                     # your token
```

---

## 6. Vault's Internal Structure — How Secrets are Organized

Vault organizes everything using paths — like folders in a filesystem, but virtual (nothing is stored on disk in the path structure itself).

```
Vault
├── auth/                    ← authentication methods
│   ├── token/               ← always enabled
│   └── approle/             ← enabled manually for this project
│
└── secret/                  ← secrets engines (mounts)
    ├── aws/                 ← KV engine we enabled at path "aws/"
    │   └── terraform-project
    │         ├── aws_access_key_id
    │         └── aws_secret_access_key
    │
    └── secret/              ← default KV v2 engine in dev mode
        └── github
              └── pat
```

### KV v1 vs KV v2 — An Important Difference

| | KV v1 | KV v2 |
|--|-------|-------|
| API path | `aws/terraform-project` | `secret/data/github` |
| Versioning | No | Yes (keeps history) |
| How enabled | `vault secrets enable -path=aws kv` | default in dev mode at `secret/` |

**This is why policies must use different paths for each:**
- For `aws/` (KV v1): policy path = `aws/terraform-project`
- For `secret/` (KV v2): policy path = `secret/data/github` (note the `/data/` prefix)

This difference caused the 403 errors we encountered — the CLI adds `/data/` automatically when talking to KV v2, but the policy must explicitly allow that full path.

---

## 7. KV Secrets Engine — Storing Your First Secret

### Enable a new KV engine at a custom path

```bash
# Enable KV v1 at path "aws/"
vault secrets enable -path=aws kv

# Verify it's mounted
vault secrets list
```

### Write a secret

```bash
# KV v1 (aws/ mount)
vault kv put aws/terraform-project \
  aws_access_key_id="AKIA..." \
  aws_secret_access_key="abc123..."

# KV v2 (secret/ mount — default in dev mode)
vault kv put secret/github pat="ghp_abc123"
```

### Read a secret

```bash
# Read all fields
vault kv get aws/terraform-project

# Read one specific field (used in the pipeline)
vault kv get -field=aws_access_key_id aws/terraform-project
vault kv get -field=pat secret/github
```

### What the output looks like

```
$ vault kv get aws/terraform-project
======= Data =======
Key                    Value
---                    -----
aws_access_key_id      AKIA***************
aws_secret_access_key  ****************************
```

---

## 8. Authentication — How Clients Prove Their Identity

When you run `vault kv get ...`, Vault checks your token. But where does a token come from?

A human admin uses the **root token** directly. But a machine (like Jenkins) should never use the root token — it has unlimited access and never expires. Instead, Jenkins authenticates using **AppRole** to get a short-lived, limited token.

The flow:

```
Jenkins                         Vault
   │                              │
   │── role_id + secret_id ──────►│
   │                              │ (validates credentials)
   │◄── short-lived token ────────│
   │                              │
   │── token + "get secret" ─────►│
   │                              │ (checks token's policy)
   │◄── secret value ─────────────│
```

---

## 9. AppRole — The Authentication Method Used in This Project

AppRole is designed for machine-to-machine authentication. It uses two credentials:

| Credential | What it is | Analogy |
|-----------|-----------|---------|
| `role_id` | Identifies which role to use | Username |
| `secret_id` | Proves the caller is authorized | Password |

Both are needed together to get a token. Neither one alone is useful.

### Enable AppRole

```bash
vault auth enable approle
```

### Create a role

```bash
vault write auth/approle/role/jenkins-role \
  token_policies="jenkins-policy" \
  secret_id_ttl=0 \
  token_ttl=1h
```

- `token_policies` — which policy the resulting token gets
- `secret_id_ttl=0` — secret_id never expires (fine for learning; use 24h or less in production)
- `token_ttl=1h` — the token issued after login expires after 1 hour

### Get the role_id

```bash
vault read auth/approle/role/jenkins-role/role-id
```

Output:
```
role_id    3d9d5f8e-1234-abcd-5678-abc123def456
```

### Generate a secret_id

```bash
vault write -f auth/approle/role/jenkins-role/secret-id
```

Output:
```
secret_id             9b5e3a2f-abcd-1234-efgh-789xyz012345
secret_id_accessor    abc123...
secret_id_ttl         0s
```

**Save both the `role_id` and `secret_id` — you store these in Jenkins credentials.**

### Test the login manually

```bash
vault write -field=token auth/approle/login \
  role_id="3d9d5f8e-..." \
  secret_id="9b5e3a2f-..."
```

This returns a token. That token is what the pipeline uses for all subsequent secret reads.

---

## 10. Policies — Controlling What Each Client Can Access

A policy is a set of rules that define what paths a token can access and what operations it can perform.

### Policy syntax

```hcl
path "aws/terraform-project" {
  capabilities = ["read"]
}

path "secret/data/github" {
  capabilities = ["read"]
}
```

### Available capabilities

| Capability | What it allows |
|-----------|---------------|
| `read` | Read secrets at this path |
| `write` | Write/create secrets |
| `delete` | Delete secrets |
| `list` | List secrets at this path |
| `create` | Create new secrets |
| `update` | Update existing secrets |

### Why `secret/data/github` and not `secret/github`?

Because `secret/` uses KV v2. When you run `vault kv get secret/github`, the CLI automatically translates this to an API call at `/v1/secret/data/github`. The policy must match the actual API path — which includes `/data/`.

For KV v1 (`aws/` mount), there is no `/data/` prefix — the API path is exactly `aws/terraform-project`.

### Write and apply the policy

```bash
cat > /tmp/jenkins-policy.hcl << 'EOF'
path "aws/terraform-project" { capabilities = ["read"] }
path "secret/data/github" { capabilities = ["read"] }
EOF

vault policy write jenkins-policy /tmp/jenkins-policy.hcl
```

Verify:
```bash
vault policy read jenkins-policy
```

---

## 11. Full Setup — Step by Step for This Project

Run all of these on the **Vault server** after starting the Vault service:

```bash
# Set environment
export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="root"

# Step 1 — Enable AppRole authentication
vault auth enable approle

# Step 2 — Enable KV v1 engine at aws/ path
vault secrets enable -path=aws kv

# Step 3 — Store the secrets
vault kv put aws/terraform-project aws_access_key_id="YOUR_KEY" aws_secret_access_key="YOUR_SECRET"
vault kv put secret/github pat="YOUR_GITHUB_PAT"

# Step 4 — Write the policy
cat > /tmp/jenkins-policy.hcl << 'EOF'
path "aws/terraform-project" { capabilities = ["read"] }
path "secret/data/github" { capabilities = ["read"] }
EOF
vault policy write jenkins-policy /tmp/jenkins-policy.hcl

# Step 5 — Create the AppRole
vault write auth/approle/role/jenkins-role token_policies="jenkins-policy" secret_id_ttl=0 token_ttl=1h

# Step 6 — Get credentials for Jenkins
vault read auth/approle/role/jenkins-role/role-id
vault write -f auth/approle/role/jenkins-role/secret-id
```

Then in Jenkins, store these three credentials as **Secret Text**:

| Jenkins Credential ID | Value |
|----------------------|-------|
| `VAULT_URL` | `http://<vault-private-ip>:8200` |
| `vault-role-id` | the role_id from Step 6 |
| `vault-secret-id` | the secret_id from Step 6 |

---

## 12. How the Jenkins Pipeline Uses Vault

Here is the exact flow of the `Fetch Credentials from Vault` stage, line by line:

```groovy
withCredentials([
    string(credentialsId: 'VAULT_URL',       variable: 'VAULT_URL'),
    string(credentialsId: 'vault-role-id',   variable: 'VAULT_ROLE_ID'),
    string(credentialsId: 'vault-secret-id', variable: 'VAULT_SECRET_ID')
])
```
Jenkins loads the three credentials it knows about (Vault URL, role_id, secret_id) into environment variables. These are the ONLY secrets Jenkins stores.

```bash
export VAULT_ADDR="${VAULT_URL}"
```
Sets the Vault server address for the CLI.

```bash
VAULT_TOKEN=$(vault write -field=token auth/approle/login \
  role_id=${VAULT_ROLE_ID} \
  secret_id=${VAULT_SECRET_ID})
```
Jenkins logs into Vault using AppRole. Vault validates the role_id and secret_id, checks the AppRole configuration, and returns a short-lived token. The token is captured in `$VAULT_TOKEN`.

```bash
GIT_TOKEN=$(vault kv get -field=pat secret/github)
```
Uses the token from the previous step to read the GitHub PAT from Vault. Vault checks the token's policy — since `jenkins-policy` allows `read` on `secret/data/github`, access is granted.

```bash
AWS_ACCESS_KEY_ID=$(vault kv get -field=aws_access_key_id aws/terraform-project)
AWS_SECRET_ACCESS_KEY=$(vault kv get -field=aws_secret_access_key aws/terraform-project)
```
Same process — reads AWS credentials from Vault.

```bash
echo "export GIT_TOKEN=${GIT_TOKEN}" >> vault_env.sh
echo "export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}" >> vault_env.sh
echo "export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}" >> vault_env.sh
```
Writes all retrieved secrets to a temporary shell script (`vault_env.sh`) in the workspace. Subsequent pipeline stages source this file to load the credentials into their shell environment.

```bash
. ${WORKSPACE}/vault_env.sh
```
Sources (loads) the credentials into the current shell. After this, Terraform and AWS CLI commands can use the AWS credentials transparently.

### Visual flow

```
Jenkins (stores only)          Vault Server (stores everything)
┌─────────────────────┐        ┌──────────────────────────────┐
│ VAULT_URL           │        │ aws/terraform-project        │
│ vault-role-id  ─────┼──┐     │   aws_access_key_id          │
│ vault-secret-id─────┼──┤     │   aws_secret_access_key      │
└─────────────────────┘  │     │                              │
                         │     │ secret/github                │
          login          │     │   pat                        │
          ───────────────┘────►│                              │
          ◄─── token ──────────│                              │
                               │                              │
          get secrets ────────►│ (policy check: allowed?)     │
          ◄─── values ─────────│                              │
                               └──────────────────────────────┘
                │
                ▼
        vault_env.sh (temporary, deleted after pipeline)
        Terraform / AWS CLI use credentials from this file
```

---

## 13. What Happens When Vault Restarts

**Dev mode stores everything in memory.** When the Vault process restarts (server reboot, systemd restart, crash), everything is wiped:
- All secrets are gone
- AppRole configuration is gone
- Policies are gone
- The token is reset to `root`

You must re-run the full setup from Section 11 every time Vault restarts.

**This is the biggest limitation of dev mode.** In production Vault:
- Uses a persistent backend (file, Consul, DynamoDB, etc.)
- Data survives restarts
- Vault starts in a **sealed** state and must be **unsealed** with unseal keys before it can serve requests

For this project (learning purposes), dev mode is fine — just be aware you need to re-seed after restarts.

---

## 14. Common Errors and What They Mean

| Error | Cause | Fix |
|-------|-------|-----|
| `vault: not found` | Vault CLI not installed on the machine running the command | Install vault on that machine |
| `connection refused` | Vault server not running, or wrong IP/port | Start vault service; check VAULT_ADDR |
| `dial tcp 127.0.0.1:8200` | VAULT_URL in Jenkins set to localhost instead of Vault server's IP | Update VAULT_URL credential to Vault server's private IP |
| `403 permission denied` (on login) | Wrong role_id or secret_id; or AppRole not enabled | Re-enable AppRole; regenerate secret_id |
| `403 permission denied` (on secret read) | Policy doesn't grant access to that path | Update policy to include the correct path |
| `preflight capability check returned 403` | KV v2 path in policy is wrong (missing `/data/`) | Use `secret/data/github` not `secret/github` in policy |
| `unsupported protocol scheme ""` | VAULT_URL missing `://` (e.g., `http/` instead of `http://`) | Fix the URL format in Jenkins credentials |
| `address already in use` | Another Vault process already running on port 8200 | `sudo kill $(sudo lsof -ti :8200)` then restart |

---

## 15. Dev Mode vs Production — Key Differences

| | Dev Mode | Production |
|--|----------|-----------|
| Storage | In memory (lost on restart) | Persistent backend (file, S3, Consul) |
| Initialization | Auto-initialized | Manual: `vault operator init` |
| Seal/Unseal | Always unsealed | Must unseal after every restart |
| Root token | Fixed (`root` with `-dev-root-token-id`) | Generated once during init, should be revoked |
| TLS | Disabled | Required |
| Use case | Learning, local testing | Production workloads |
| Data persistence | No | Yes |

### Production startup sequence (for reference)

In a real production setup, after a restart:

```bash
# 1. Start the server (it starts in sealed state)
vault server -config=/etc/vault.d/vault.hcl

# 2. Initialize (first time only — generates unseal keys and root token)
vault operator init

# 3. Unseal (requires 3 of 5 unseal keys by default)
vault operator unseal <key1>
vault operator unseal <key2>
vault operator unseal <key3>

# 4. Now Vault is ready to serve requests
vault status
```

The unseal keys are critical — if you lose them, you lose access to all secrets permanently.

---

## Quick Reference — Commands Used in This Project

```bash
# Environment setup
export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="root"

# Check Vault status
vault status

# Enable secrets engines
vault secrets enable -path=aws kv
vault secrets list

# Enable auth methods
vault auth enable approle
vault auth list

# Store secrets
vault kv put aws/terraform-project aws_access_key_id="KEY" aws_secret_access_key="SECRET"
vault kv put secret/github pat="TOKEN"

# Read secrets
vault kv get aws/terraform-project
vault kv get -field=pat secret/github

# Manage policies
vault policy write jenkins-policy /tmp/jenkins-policy.hcl
vault policy read jenkins-policy
vault policy list

# Manage AppRole
vault write auth/approle/role/jenkins-role token_policies="jenkins-policy" secret_id_ttl=0 token_ttl=1h
vault read auth/approle/role/jenkins-role/role-id
vault write -f auth/approle/role/jenkins-role/secret-id

# Test AppRole login
vault write -field=token auth/approle/login role_id="ROLE_ID" secret_id="SECRET_ID"

# View service logs
journalctl -u vault -f
```
