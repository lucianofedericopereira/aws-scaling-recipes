# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [2.0.0] — 2026-02-15

### Changed — Breaking (rename)
- All `buschi-*` files and resource names renamed to `vertical-*` (generic pattern)
- All `noblex-*` / `NEWSAN-*` files and resource names renamed to `horizontal-*` (generic pattern)
- Stack names updated: `buschi-*` → `vertical-scaling-*`, `noblex-*` → `horizontal-scaling-*`
- SSM paths updated: `/buschi/db-password` → `/vertical-scaling/db-password`, `/noblex/db-password` → `/horizontal-scaling/db-password`
- `buschi-aws-batch.yaml` renamed to `vertical-batch-overflow.yaml`
- ECR image reference updated: `buschi-print:latest` → `vertical-scaling-processor:latest`
- RDS Proxy Secrets Manager path: `noblex/db-credentials` → `horizontal-scaling/db-credentials`

### Added
- `config.env` — single file for all deployment parameters; sourced by all scripts
- `deploy.sh` — unified entry point with `check`, `vertical`, `horizontal`, `both`, `destroy` commands
- `deploy.sh check` — prerequisites validation (AWS CLI v2, credentials, config.env, SSM params)
- `deploy.sh destroy` — interactive stack teardown in reverse dependency order
- `Makefile` — `validate`, `lint-shell`, `lint`, `deploy-*`, `check`, `destroy` targets
- `.github/workflows/ci.yml` — CI with cfn-lint, shellcheck, gitleaks, placeholder check
- `.pre-commit-config.yaml` — pre-commit hooks (gitleaks, shellcheck, cfn-lint, general hygiene)
- `CHANGELOG.md` (this file)

### Changed — Templates
- `vertical-ebs-volumes.yaml`: updated `gp2` to `gp3` (better baseline IOPS, lower cost)
- `vertical-rds-scaling.yaml`: updated `db.m4.large` → `db.m5.large` (m4 retired); PostgreSQL 14.10 → 16.3
- `horizontal-asg-config.yaml`: replaced hardcoded Oct 2022 cron dates with `PromoWarmupCron`/`PromoCooldownCron` parameters sourced from `config.env`
- `horizontal-aurora-serverless.yaml`: PostgreSQL 14.6 → 16.2; updated `RdsProxyRole` resource name and Secrets Manager path
- `horizontal-elasticache-redis.yaml`: Redis engine version 7.0 → 7.1
- `vertical-ec2-strategy.yaml`: AMI default updated from Amazon Linux 2 (`amzn2-ami-hvm-x86_64-gp2`) to Amazon Linux 2023 (`al2023-ami-kernel-default-x86_64`)
- All templates: `Project` tag key renamed to `ScalingPattern` with value `vertical` or `horizontal`
- All templates: enhanced inline comments explaining design rationale and adaptation guidance
- Launch scripts: configuration variables removed; all values sourced from `config.env`
- Launch scripts: `set -euo pipefail` + absolute paths via `SCRIPT_DIR`/`REPO_ROOT`
- `main.sh`: simplified to delegate to `deploy.sh`

### Fixed
- Hardcoded October 2022 scheduled scaling dates (now parameterized via `config.env`)
- `launch_horizontal.sh` referenced `noblex/production/` SSM path in UserData (now generic)
- `buschi-rds-scaling.yaml` used deprecated `BuschiSecurityGroupId` parameter name (now `AppSecurityGroupId`)

---

## [1.0.0] — 2022-10-30

### Added
- Initial release with vertical (Buschi/Artes Graficas) and horizontal (Noblex/NEWSAN) patterns
- 13 CloudFormation templates covering EC2, RDS, S3, SQS, ALB, ASG, Aurora, ElastiCache, CloudFront, Batch, CloudWatch
- `launch_vertical.sh` and `launch_horizontal.sh` deployment scripts
- `main.sh` entry point dispatcher
