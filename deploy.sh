#!/bin/bash
#
# AWS Scaling Recipes — deploy.sh
# Single entry point for deploying vertical or horizontal scaling recipes.
#
# Usage:
#   ./deploy.sh vertical     Deploy the vertical scaling recipe (6 CF stacks)
#   ./deploy.sh horizontal   Deploy the horizontal scaling recipe (7 CF stacks)
#   ./deploy.sh both         Deploy both recipes sequentially
#   ./deploy.sh check        Run prerequisites check only (no deployment)
#   ./deploy.sh destroy      Destroy all stacks (with confirmation)
#
# Before first deploy:
#   1. Edit config.env and fill in your VPC, subnet, and certificate values
#   2. Store DB passwords in SSM Parameter Store (see config.env for commands)
#   3. For horizontal: create Secrets Manager secret for RDS Proxy

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Prerequisites check
# ---------------------------------------------------------------------------
check_prerequisites() {
  local errors=0

  echo "--- Checking prerequisites ---"

  # AWS CLI v2
  if ! command -v aws &>/dev/null; then
    echo "  [FAIL] aws CLI not found. Install AWS CLI v2: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    errors=$((errors + 1))
  else
    local cli_version
    cli_version=$(aws --version 2>&1 | awk '{print $1}' | cut -d/ -f2)
    local cli_major
    cli_major=$(echo "${cli_version}" | cut -d. -f1)
    if [[ "${cli_major}" -lt 2 ]]; then
      echo "  [FAIL] AWS CLI v2 required, found v${cli_version}"
      errors=$((errors + 1))
    else
      echo "  [OK]   AWS CLI v${cli_version}"
    fi
  fi

  # AWS credentials
  if ! aws sts get-caller-identity &>/dev/null; then
    echo "  [FAIL] AWS credentials not configured or not valid. Run: aws configure"
    errors=$((errors + 1))
  else
    local account region
    account=$(aws sts get-caller-identity --query Account --output text)
    region=$(aws configure get region 2>/dev/null || echo "not set")
    echo "  [OK]   AWS account: ${account}, default region: ${region}"
  fi

  # config.env
  if [[ ! -f "${REPO_ROOT}/config.env" ]]; then
    echo "  [FAIL] config.env not found. Edit config.env and fill in your values."
    errors=$((errors + 1))
  else
    # shellcheck source=config.env
    source "${REPO_ROOT}/config.env"
    local placeholders
    placeholders=$(grep -c "REPLACE_ME" "${REPO_ROOT}/config.env" || true)
    if [[ "${placeholders}" -gt 0 ]]; then
      echo "  [WARN] config.env has ${placeholders} unreplaced REPLACE_ME placeholder(s)"
    else
      echo "  [OK]   config.env (no placeholders found)"
    fi
  fi

  # Vertical SSM parameter
  if [[ -f "${REPO_ROOT}/config.env" ]]; then
    source "${REPO_ROOT}/config.env"
    if aws ssm get-parameter --name "${VERTICAL_DB_PASSWORD_PARAM}" \
        --region "${REGION}" &>/dev/null 2>&1; then
      echo "  [OK]   SSM parameter ${VERTICAL_DB_PASSWORD_PARAM} exists"
    else
      echo "  [WARN] SSM parameter ${VERTICAL_DB_PASSWORD_PARAM} not found"
      echo "         Run: aws ssm put-parameter --name ${VERTICAL_DB_PASSWORD_PARAM} --value 'YourPassword' --type SecureString --region ${REGION}"
    fi

    if aws ssm get-parameter --name "${HORIZONTAL_DB_PASSWORD_PARAM}" \
        --region "${REGION}" &>/dev/null 2>&1; then
      echo "  [OK]   SSM parameter ${HORIZONTAL_DB_PASSWORD_PARAM} exists"
    else
      echo "  [WARN] SSM parameter ${HORIZONTAL_DB_PASSWORD_PARAM} not found"
      echo "         Run: aws ssm put-parameter --name ${HORIZONTAL_DB_PASSWORD_PARAM} --value 'YourPassword' --type SecureString --region ${REGION}"
    fi
  fi

  echo ""
  if [[ "${errors}" -gt 0 ]]; then
    echo "Prerequisites check failed with ${errors} error(s). Fix the issues above before deploying."
    return 1
  else
    echo "Prerequisites check passed."
    return 0
  fi
}

# ---------------------------------------------------------------------------
# Destroy all stacks (with confirmation)
# ---------------------------------------------------------------------------
destroy_all() {
  echo "WARNING: This will delete all vertical and horizontal scaling stacks."
  echo "All RDS and EBS resources with DeletionPolicy: Snapshot will create snapshots first."
  echo ""
  read -r -p "Type 'destroy' to confirm: " confirm
  if [[ "${confirm}" != "destroy" ]]; then
    echo "Aborted."
    exit 1
  fi

  local stacks=(
    "vertical-scaling-cloudwatch"
    "vertical-scaling-batch-overflow"
    "vertical-scaling-rds"
    "vertical-scaling-ec2-strategy"
    "vertical-scaling-ebs-volumes"
    "vertical-scaling-s3-sqs-pipeline"
    "horizontal-scaling-observability"
    "horizontal-scaling-cloudfront"
    "horizontal-scaling-sqs"
    "horizontal-scaling-redis"
    "horizontal-scaling-aurora"
    "horizontal-scaling-asg"
    "horizontal-scaling-alb"
  )

  source "${REPO_ROOT}/config.env"

  for stack in "${stacks[@]}"; do
    if aws cloudformation describe-stacks \
        --stack-name "${stack}" --region "${REGION}" &>/dev/null 2>&1; then
      echo "Deleting stack: ${stack}..."
      aws cloudformation delete-stack \
        --stack-name "${stack}" --region "${REGION}"
      aws cloudformation wait stack-delete-complete \
        --stack-name "${stack}" --region "${REGION}"
      echo "  Deleted: ${stack}"
    else
      echo "  Skipped (not found): ${stack}"
    fi
  done

  echo ""
  echo "All stacks deleted."
}

# ---------------------------------------------------------------------------
# Main dispatcher
# ---------------------------------------------------------------------------
COMMAND="${1:-}"

case "${COMMAND}" in
  vertical)
    check_prerequisites
    chmod +x "${REPO_ROOT}/Vertical/launch_vertical.sh"
    "${REPO_ROOT}/Vertical/launch_vertical.sh"
    ;;
  horizontal)
    check_prerequisites
    chmod +x "${REPO_ROOT}/Horizontal/launch_horizontal.sh"
    "${REPO_ROOT}/Horizontal/launch_horizontal.sh"
    ;;
  both)
    check_prerequisites
    chmod +x "${REPO_ROOT}/Vertical/launch_vertical.sh"
    chmod +x "${REPO_ROOT}/Horizontal/launch_horizontal.sh"
    "${REPO_ROOT}/Vertical/launch_vertical.sh"
    "${REPO_ROOT}/Horizontal/launch_horizontal.sh"
    ;;
  check)
    check_prerequisites
    ;;
  destroy)
    destroy_all
    ;;
  *)
    echo "AWS Scaling Recipes — deploy.sh"
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  check        Verify prerequisites (AWS CLI, credentials, config.env, SSM params)"
    echo "  vertical     Deploy the vertical scaling recipe (6 CloudFormation stacks)"
    echo "  horizontal   Deploy the horizontal scaling recipe (7 CloudFormation stacks)"
    echo "  both         Deploy both recipes sequentially"
    echo "  destroy      Delete all stacks (with confirmation prompt)"
    echo ""
    echo "Before deploying, edit config.env and run: $0 check"
    ;;
esac
