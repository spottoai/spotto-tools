---
name: spotto-tools-architecture
description: Repo-specific architecture for Spotto onboarding tools and scripts.
---

Status: living
Last updated: 2026-02-15
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
- Downstream: Azure AD and subscription permissions configured for Spotto access.
- Primary responsibility: automate creation of service principals and required permissions.

## Key components
- `onboarding/azure/Setup-SpottoAzure.ps1` - main Azure onboarding script.
- `onboarding/azure/README.md` - onboarding guidance and parameters.

## Data flow (happy path)
1. Operator runs onboarding script.
2. Script creates service principal and assigns required roles/permissions.
3. Credentials are provided for use in the Spotto portal.

## Runtime & deployment notes
- PowerShell scripts; run locally by customers.
- Documentation lives in repo and external docs site.

## Integration boundaries & invariants
- Permissions granted must align with Spotto onboarding requirements.
- Scripts should remain idempotent and safe to re-run.
