#!/bin/bash
#
# Launch script — Noblex / NEWSAN (Horizontal Scaling) CloudFormation stacks
# Deploys all 7 Noblex stacks in dependency order.
#
# Prerequisites:
#   - AWS CLI configured with appropriate IAM permissions
#   - An existing ACM certificate in the deployment region
#   - A WAF Web ACL in us-east-1 (required for CloudFront)
#   - VPC with public and private subnets across at least 2 AZs
#
# Usage: ./launch_noblex.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — update these before deploying
# ---------------------------------------------------------------------------
REGION="us-east-1"
KEY_NAME="noblex-prod-key"
VPC_ID="vpc-REPLACE_ME"
PUBLIC_SUBNET_IDS="subnet-REPLACE_ME1,subnet-REPLACE_ME2"
PRIVATE_SUBNET_IDS="subnet-REPLACE_ME3,subnet-REPLACE_ME4"
CERTIFICATE_ARN="arn:aws:acm:us-east-1:ACCOUNT_ID:certificate/REPLACE_ME"
WAF_ACL_ARN="arn:aws:wafv2:us-east-1:ACCOUNT_ID:global/webacl/noblex-protection/REPLACE_ME"
OPS_EMAIL="ops@example.com"
PAGERDUTY_ENDPOINT="https://events.pagerduty.com/integration/REPLACE_ME/enqueue"
DB_PASSWORD_PARAM="/noblex/db-password"

# ---------------------------------------------------------------------------
echo "=== Noblex / NEWSAN Infrastructure Deployment ==="
echo "Region:  $REGION"
echo "VPC:     $VPC_ID"
echo ""

DB_PASSWORD=$(aws ssm get-parameter --name "$DB_PASSWORD_PARAM" \
  --with-decryption --region "$REGION" --output text --query 'Parameter.Value')

# 1. ALB (no upstream dependencies)
echo "[1/7] Deploying ALB..."
aws cloudformation deploy \
  --stack-name noblex-alb-config \
  --template-file noblex-alb-config.yaml \
  --region "$REGION" \
  --parameter-overrides \
      VpcId="$VPC_ID" \
      PublicSubnetIds="$PUBLIC_SUBNET_IDS" \
      CertificateArn="$CERTIFICATE_ARN"

ALB_ARN=$(aws cloudformation describe-stacks \
  --stack-name noblex-alb-config \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='ALBArn'].OutputValue" \
  --output text)
ALB_DNS=$(aws cloudformation describe-stacks \
  --stack-name noblex-alb-config \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='ALBDnsName'].OutputValue" \
  --output text)
TG_ARN=$(aws cloudformation describe-stacks \
  --stack-name noblex-alb-config \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='TargetGroupArn'].OutputValue" \
  --output text)

# 2. ASG (depends on ALB target group)
echo "[2/7] Deploying Auto Scaling Group..."
aws cloudformation deploy \
  --stack-name noblex-asg-config \
  --template-file noblex-asg-config.yaml \
  --region "$REGION" \
  --parameter-overrides \
      VpcId="$VPC_ID" \
      SubnetIds="$PUBLIC_SUBNET_IDS" \
      KeyName="$KEY_NAME" \
      AlbTargetGroupArn="$TG_ARN"

APP_SG=$(aws cloudformation describe-stacks \
  --stack-name noblex-asg-config \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='AppSecurityGroupId'].OutputValue" \
  --output text)

# 3. Aurora Serverless v2 (depends on app security group)
echo "[3/7] Deploying Aurora Serverless v2..."
aws cloudformation deploy \
  --stack-name noblex-aurora-serverless \
  --template-file noblex-aurora-serverless.yaml \
  --region "$REGION" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      VpcId="$VPC_ID" \
      DbSubnetIds="$PRIVATE_SUBNET_IDS" \
      AppSecurityGroupId="$APP_SG" \
      DBPassword="$DB_PASSWORD"

# 4. ElastiCache Redis (depends on app security group)
echo "[4/7] Deploying ElastiCache Redis..."
aws cloudformation deploy \
  --stack-name noblex-elasticache-redis \
  --template-file noblex-elasticache-redis.yaml \
  --region "$REGION" \
  --parameter-overrides \
      VpcId="$VPC_ID" \
      CacheSubnetIds="$PRIVATE_SUBNET_IDS" \
      AppSecurityGroupId="$APP_SG"

# 5. SQS queues (no dependencies)
echo "[5/7] Deploying SQS queues..."
aws cloudformation deploy \
  --stack-name noblex-sqs-queues \
  --template-file noblex-sqs-queues.yaml \
  --region "$REGION"

# 6. CloudFront CDN (depends on ALB DNS name)
echo "[6/7] Deploying CloudFront CDN..."
aws cloudformation deploy \
  --stack-name noblex-cloudfront \
  --template-file noblex-cloudfront.yaml \
  --region "$REGION" \
  --parameter-overrides \
      AlbDnsName="$ALB_DNS" \
      WafWebAclArn="$WAF_ACL_ARN"

# 7. Observability (depends on ASG name, ALB ARN, TG ARN)
echo "[7/7] Deploying observability (CloudWatch alarms)..."
ASG_NAME=$(aws cloudformation describe-stacks \
  --stack-name noblex-asg-config \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='AutoScalingGroupName'].OutputValue" \
  --output text)
aws cloudformation deploy \
  --stack-name noblex-observability \
  --template-file noblex-observability.yaml \
  --region "$REGION" \
  --parameter-overrides \
      OpsTeamEmail="$OPS_EMAIL" \
      PagerDutyEndpoint="$PAGERDUTY_ENDPOINT" \
      AsgName="$ASG_NAME" \
      AlbArn="$ALB_ARN" \
      TargetGroupArn="$TG_ARN"

echo ""
echo "=== Noblex deployment complete ==="
