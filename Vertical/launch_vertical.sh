#!/bin/bash
#
# Vertical Scaling Recipe — CloudFormation deployment
# Deploys all 6 vertical scaling stacks in dependency order.
#
# Usage: ./Vertical/launch_vertical.sh
# Or:    ./deploy.sh vertical
#
# Prerequisites:
#   1. Fill in config.env at the repo root
#   2. Store DB password in SSM:
#      aws ssm put-parameter --name /vertical-scaling/db-password \
#        --value 'YourPassword' --type SecureString --region <region>
#   3. Build and push your processing container to ECR:
#      <account>.dkr.ecr.<region>.amazonaws.com/vertical-scaling-processor:latest

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source shared configuration
if [[ ! -f "${REPO_ROOT}/config.env" ]]; then
  echo "ERROR: config.env not found at ${REPO_ROOT}/config.env"
  echo "Copy config.env, fill in your values, then re-run."
  exit 1
fi
# shellcheck source=../config.env
source "${REPO_ROOT}/config.env"

echo "=== Vertical Scaling Recipe — Deployment ==="
echo "Region:  ${REGION}"
echo "VPC:     ${VPC_ID}"
echo ""

# Retrieve DB password from SSM Parameter Store
DB_PASSWORD=$(aws ssm get-parameter \
  --name "${VERTICAL_DB_PASSWORD_PARAM}" \
  --with-decryption \
  --region "${REGION}" \
  --output text \
  --query 'Parameter.Value')

# 1. S3 + SQS job pipeline (no dependencies)
echo "[1/6] Deploying S3 + SQS pipeline..."
aws cloudformation deploy \
  --stack-name vertical-scaling-s3-sqs-pipeline \
  --template-file "${SCRIPT_DIR}/vertical-s3-sqs-pipeline.yaml" \
  --region "${REGION}" \
  --capabilities CAPABILITY_NAMED_IAM

# 2. EBS volumes
echo "[2/6] Deploying EBS volumes..."
aws cloudformation deploy \
  --stack-name vertical-scaling-ebs-volumes \
  --template-file "${SCRIPT_DIR}/vertical-ebs-volumes.yaml" \
  --region "${REGION}" \
  --parameter-overrides AvailabilityZone="${VERTICAL_AZ}"

# 3. EC2 instances (compute nodes)
echo "[3/6] Deploying EC2 instances..."
aws cloudformation deploy \
  --stack-name vertical-scaling-ec2-strategy \
  --template-file "${SCRIPT_DIR}/vertical-ec2-strategy.yaml" \
  --region "${REGION}" \
  --parameter-overrides \
      KeyName="${VERTICAL_KEY_NAME}" \
      VpcId="${VPC_ID}" \
      SubnetId="${VERTICAL_SUBNET_ID}"

EC2_SG=$(aws cloudformation describe-stacks \
  --stack-name vertical-scaling-ec2-strategy \
  --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='SecurityGroupId'].OutputValue" \
  --output text)

# 4. RDS (depends on EC2 security group)
echo "[4/6] Deploying RDS..."
aws cloudformation deploy \
  --stack-name vertical-scaling-rds \
  --template-file "${SCRIPT_DIR}/vertical-rds-scaling.yaml" \
  --region "${REGION}" \
  --parameter-overrides \
      VpcId="${VPC_ID}" \
      DbSubnetIds="${VERTICAL_DB_SUBNET_IDS}" \
      AppSecurityGroupId="${EC2_SG}" \
      DBPassword="${DB_PASSWORD}"

DB_INSTANCE_ID=$(aws cloudformation describe-stacks \
  --stack-name vertical-scaling-rds \
  --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='DBInstanceIdentifier'].OutputValue" \
  --output text)

# 5. AWS Batch overflow processing
echo "[5/6] Deploying AWS Batch overflow..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BATCH_SERVICE_ROLE="arn:aws:iam::${ACCOUNT_ID}:role/AWSBatchServiceRole"
ECS_INSTANCE_ROLE="arn:aws:iam::${ACCOUNT_ID}:instance-profile/ecsInstanceRole"

aws cloudformation deploy \
  --stack-name vertical-scaling-batch-overflow \
  --template-file "${SCRIPT_DIR}/vertical-batch-overflow.yaml" \
  --region "${REGION}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      BatchServiceRoleArn="${BATCH_SERVICE_ROLE}" \
      EcsInstanceRoleArn="${ECS_INSTANCE_ROLE}" \
      VpcId="${VPC_ID}" \
      SubnetIds="${VERTICAL_SUBNET_ID}"

# 6. CloudWatch monitoring
echo "[6/6] Deploying CloudWatch alarms..."
EC2_INSTANCE_ID=$(aws cloudformation describe-stacks \
  --stack-name vertical-scaling-ec2-strategy \
  --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='ComputeNodeInstanceId'].OutputValue" \
  --output text)

aws cloudformation deploy \
  --stack-name vertical-scaling-cloudwatch \
  --template-file "${SCRIPT_DIR}/vertical-cloudwatch.yaml" \
  --region "${REGION}" \
  --parameter-overrides \
      OpsTeamEmail="${OPS_EMAIL}" \
      Ec2InstanceId="${EC2_INSTANCE_ID}" \
      DbInstanceIdentifier="${DB_INSTANCE_ID}"

echo ""
echo "=== Vertical scaling deployment complete ==="
echo ""
echo "Deployed stacks:"
echo "  vertical-scaling-s3-sqs-pipeline"
echo "  vertical-scaling-ebs-volumes"
echo "  vertical-scaling-ec2-strategy"
echo "  vertical-scaling-rds"
echo "  vertical-scaling-batch-overflow"
echo "  vertical-scaling-cloudwatch"
