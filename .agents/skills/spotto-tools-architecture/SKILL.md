---
name: spotto-tools-architecture
description: Repo-specific architecture for Spotto onboarding tools and scripts.
---

Status: living
Last updated: 2026-10-22
Owner: TBD
Related docs: README.md, DEPLOYMENT.md, onboarding/azure/README.md, ../core/skills/system-architecture/references/system-map.md

# spotto-tools-architecture

## Purpose
Defines the architecture of the Spotto tooling repo that provides onboarding scripts and utilities for customers and partners.

## Scope
- Covers onboarding scripts and documentation in this repo.
- Excludes runtime services and platform infrastructure.

## System context
- Upstream: Operators and customers onboarding to Spotto.
- Downstream: Azure AD/subscription permissions and customer-managed AWS IAM roles configured for Spotto access.
- Primary responsibility: automate service-principal/IAM-role setup and required permissions.

## Key components
- `onboarding/azure/Setup-SpottoAzure.ps1` - main Azure onboarding script.
- `onboarding/azure/README.md` - onboarding guidance and parameters.
- `onboarding/aws/connect.sh` / `onboarding/aws/Connect-SpottoAws.ps1` - thin AWS connect wrappers: detect account, organization and exports, then deploy the hosted CloudFormation templates.
- `onboarding/aws/cloudformation/` - generated CloudFormation templates (from `api/scripts/aws/generate-connect-templates.ts`), published to S3 by `.github/workflows/publish-aws-cloudformation.yml`.
- `onboarding/aws/README.md` - CloudShell command, flags and troubleshooting.

## Data flow (happy path)
1. Operator runs onboarding script.
2. Script creates service principal and assigns required roles/permissions.
3. Credentials are provided for use in the Spotto portal.

## Runtime & deployment notes
- PowerShell and Bash scripts; run locally by customers or in cloud shells.
- Documentation lives in repo and external docs site.

## Integration boundaries & invariants
- Permissions granted must align with Spotto onboarding requirements.
- Scripts should remain idempotent and safe to re-run.
- Customer onboarding entrypoints are single `.ps1` or `.sh` files.
- AWS: CloudFormation is the single source of truth for the role and policies. The
  scripts never author IAM policies; they only choose template parameters and deploy
  `SpottoConnect`, `SpottoBillingAccess` and `SpottoMemberAccounts` in the API-supplied region, with a separate us-east-1 billing-definition stack.
  Reruns update stacks to the versioned template URL with `UsePreviousValue` for
  unchanged parameters (idempotent); `--repair` uses `RepairToken`, `--check` is read-only.
  Bash needs only AWS CLI v2 (`--query`/`--output text`, no jq) so it runs in CloudShell.
  Offline tests (`onboarding/aws/tests/`) run both scripts against `fake_aws.py`.
- Spec: `core/specs/cloud-accounts/connections/assisted-connection/assisted-connection-aws.md`.
