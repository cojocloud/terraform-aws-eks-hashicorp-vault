---
name: Project Context — terraform-aws-eks-hashicorp-vault
description: Origin and goals for the EKS/Vault Terraform project the user is customizing
type: project
---

User copied this project from a GitHub repo (original author: SubbuTechOps) and wants to customize and reproduce it for their own use.

**Why:** Learning/portfolio project — end-to-end IaC pipeline provisioning EKS with Jenkins CI/CD and HashiCorp Vault for secrets.

**How to apply:** When suggesting changes, frame them as customizations the user needs to make their own copy work (bucket names, repo URLs, credentials). The user is learning the stack, so explain the why behind each component.

**Work done in first session (2026-04-26):**
- Full code review completed
- README.md rewritten with architecture diagram (ASCII) and phased implementation steps
- IMPLEMENTATION_GUIDE.md created (explains every file, every design decision)
- Applied 5 code fixes:
  1. autoscaler-manifest.tf: k8s.gcr.io → registry.k8s.io, v1.23.1 → v1.27.8
  2. Jenkinsfile: removed two echo lines that printed AWS credentials in plain text
  3. monitoring.tf: Prometheus memory limit 50Mi → 1Gi (was too low to run)
  4. provider.tf: added explicit aws and kubernetes provider declarations
  5. variables.tf: cluster_version type number → string
