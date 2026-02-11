#!/bin/bash
#
# Launch script — Buschi (Vertical Scaling) CloudFormation stacks
# Deploys all 6 Buschi stacks in dependency order.
#
# Prerequisites:
#   - AWS CLI configured with appropriate IAM permissions
#   - An existing EC2 Key Pair (set KEY_NAME below)
#   - A VPC with at least one subnet and security group
#
# Usage: ./launch_buschi.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — update these before deploying
# ---------------------------------------------------------------------------
REGION="us-east-1"
KEY_NAME="buschi-prod-key"
VPC_ID="vpc-REPLACE_ME"
SUBNET_ID="subnet-REPLACE_ME"
DB_SUBNET_IDS="subnet-REPLACE_ME1,subnet-REPLACE_ME2"
AZ="${REGION}a"
OPS_EMAIL="ops@example.com"
DB_PASSWORD_PARAM="/buschi/db-password"   # Store password in SSM Parameter Store

# ---------------------------------------------------------------------------
echo "=== Buschi Infrastructure Deployment ==="
echo "Region:  $REGION"
echo "VPC:     $VPC_ID"
echo ""

# Retrieve DB password from SSM Parameter Store (set it beforehand with:
#   aws ssm put-parameter --name /buschi/db-password --value 'YOURPASSWORD' --type SecureString)
DB_PASSWORD=$(aws ssm get-parameter --name "$DB_PASSWORD_PARAM" \
  --with-decryption --region "$REGION" --output text --query 'Parameter.Value')

# 1. S3 + SQS job pipeline (no dependencies)
echo "[1/6] Deploying S3 + SQS pipeline..."
aws cloudformation deploy \
  --stack-name buschi-s3-sqs-pipeline \
  --template-file buschi-s3-sqs-pipeline.yaml \
  --region "$REGION" \
  --capabilities CAPABILITY_NAMED_IAM

# 2. EBS volumes
echo "[2/6] Deploying EBS volumes..."
aws cloudformation deploy \
  --stack-name buschi-ebs-volumes \
  --template-file buschi-ebs-volumes.yaml \
  --region "$REGION" \
  --parameter-overrides AvailabilityZone="$AZ"

# 3. EC2 instances (compute nodes)
echo "[3/6] Deploying EC2 instances..."
aws cloudformation deploy \
  --stack-name buschi-ec2-strategy \
  --template-file buschi-ec2-strategy.yaml \
  --region "$REGION" \
  --parameter-overrides \
      KeyName="$KEY_NAME" \
      VpcId="$VPC_ID" \
      SubnetId="$SUBNET_ID"

EC2_SG=$(aws cloudformation describe-stacks \
  --stack-name buschi-ec2-strategy \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='SecurityGroupId'].OutputValue" \
  --output text)

# 4. RDS (depends on EC2 security group)
echo "[4/6] Deploying RDS..."
aws cloudformation deploy \
  --stack-name buschi-rds-scaling \
  --template-file buschi-rds-scaling.yaml \
  --region "$REGION" \
  --parameter-overrides \
      VpcId="$VPC_ID" \
      DbSubnetIds="$DB_SUBNET_IDS" \
      BuschiSecurityGroupId="$EC2_SG" \
      DBPassword="$DB_PASSWORD"

# 5. AWS Batch (overflow processing)
echo "[5/6] Deploying AWS Batch..."
BATCH_SERVICE_ROLE="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/AWSBatchServiceRole"
ECS_INSTANCE_ROLE="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):instance-profile/ecsInstanceRole"
aws cloudformation deploy \
  --stack-name buschi-aws-batch \
  --template-file buschi-aws-batch.yaml \
  --region "$REGION" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      BatchServiceRoleArn="$BATCH_SERVICE_ROLE" \
      EcsInstanceRoleArn="$ECS_INSTANCE_ROLE" \
      VpcId="$VPC_ID" \
      SubnetIds="$SUBNET_ID"

# 6. CloudWatch monitoring
echo "[6/6] Deploying CloudWatch alarms..."
EC2_INSTANCE_ID=$(aws cloudformation describe-stacks \
  --stack-name buschi-ec2-strategy \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='PdfFlatteningInstanceId'].OutputValue" \
  --output text)
aws cloudformation deploy \
  --stack-name buschi-cloudwatch \
  --template-file buschi-cloudwatch.yaml \
  --region "$REGION" \
  --parameter-overrides \
      OpsTeamEmail="$OPS_EMAIL" \
      Ec2InstanceId="$EC2_INSTANCE_ID" \
      DbInstanceIdentifier="buschi-print-metadata"

echo ""
echo "=== Buschi deployment complete ==="
