#!/bin/bash
#
# Horizontal Scaling Recipe — CloudFormation deployment
# Deploys all 7 horizontal scaling stacks in dependency order.
#
# Usage: ./Horizontal/launch_horizontal.sh
# Or:    ./deploy.sh horizontal
#
# Prerequisites:
#   1. Fill in config.env at the repo root
#   2. Store DB password in SSM:
#      aws ssm put-parameter --name /horizontal-scaling/db-password \
#        --value 'YourPassword' --type SecureString --region <region>
#   3. Create Secrets Manager secret for RDS Proxy:
#      aws secretsmanager create-secret --name horizontal-scaling/db-credentials \
#        --secret-string '{"username":"app_admin","password":"YourPassword"}'
#   4. Provision ACM certificate in $REGION and note the ARN
#   5. Create WAF Web ACL in us-east-1 and note the ARN

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source shared configuration
if [[ ! -f "${REPO_ROOT}/config.env" ]]; then
  echo "ERROR: config.env not found at ${REPO_ROOT}/config.env"
  echo "Copy config.env, fill in your values, then re-run."
  exit 1
fi
# shellcheck source=config.env
source "${REPO_ROOT}/config.env"

echo "=== Horizontal Scaling Recipe — Deployment ==="
echo "Region:  ${REGION}"
echo "VPC:     ${VPC_ID}"
echo ""

# Retrieve DB password from SSM Parameter Store
DB_PASSWORD=$(aws ssm get-parameter \
  --name "${HORIZONTAL_DB_PASSWORD_PARAM}" \
  --with-decryption \
  --region "${REGION}" \
  --output text \
  --query 'Parameter.Value')

# 1. ALB (no upstream dependencies)
echo "[1/7] Deploying ALB..."
aws cloudformation deploy \
  --stack-name horizontal-scaling-alb \
  --template-file "${SCRIPT_DIR}/horizontal-alb-config.yaml" \
  --region "${REGION}" \
  --parameter-overrides \
      VpcId="${VPC_ID}" \
      PublicSubnetIds="${HORIZONTAL_PUBLIC_SUBNET_IDS}" \
      CertificateArn="${CERTIFICATE_ARN}"

ALB_ARN=$(aws cloudformation describe-stacks \
  --stack-name horizontal-scaling-alb \
  --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='ALBArn'].OutputValue" \
  --output text)
ALB_DNS=$(aws cloudformation describe-stacks \
  --stack-name horizontal-scaling-alb \
  --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='ALBDnsName'].OutputValue" \
  --output text)
TG_ARN=$(aws cloudformation describe-stacks \
  --stack-name horizontal-scaling-alb \
  --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='TargetGroupArn'].OutputValue" \
  --output text)

# 2. ASG (depends on ALB target group)
echo "[2/7] Deploying Auto Scaling Group..."
aws cloudformation deploy \
  --stack-name horizontal-scaling-asg \
  --template-file "${SCRIPT_DIR}/horizontal-asg-config.yaml" \
  --region "${REGION}" \
  --parameter-overrides \
      VpcId="${VPC_ID}" \
      SubnetIds="${HORIZONTAL_PUBLIC_SUBNET_IDS}" \
      KeyName="${HORIZONTAL_KEY_NAME}" \
      AlbTargetGroupArn="${TG_ARN}" \
      PromoWarmupCron="${PROMO_WARMUP_CRON}" \
      PromoCooldownCron="${PROMO_COOLDOWN_CRON}"

APP_SG=$(aws cloudformation describe-stacks \
  --stack-name horizontal-scaling-asg \
  --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='AppSecurityGroupId'].OutputValue" \
  --output text)

# 3. Aurora Serverless v2 (depends on app security group)
echo "[3/7] Deploying Aurora Serverless v2..."
aws cloudformation deploy \
  --stack-name horizontal-scaling-aurora \
  --template-file "${SCRIPT_DIR}/horizontal-aurora-serverless.yaml" \
  --region "${REGION}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      VpcId="${VPC_ID}" \
      DbSubnetIds="${HORIZONTAL_PRIVATE_SUBNET_IDS}" \
      AppSecurityGroupId="${APP_SG}" \
      DBPassword="${DB_PASSWORD}"

# 4. ElastiCache Redis (depends on app security group)
echo "[4/7] Deploying ElastiCache Redis..."
aws cloudformation deploy \
  --stack-name horizontal-scaling-redis \
  --template-file "${SCRIPT_DIR}/horizontal-elasticache-redis.yaml" \
  --region "${REGION}" \
  --parameter-overrides \
      VpcId="${VPC_ID}" \
      CacheSubnetIds="${HORIZONTAL_PRIVATE_SUBNET_IDS}" \
      AppSecurityGroupId="${APP_SG}"

# 5. SQS queues (no dependencies)
echo "[5/7] Deploying SQS queues..."
aws cloudformation deploy \
  --stack-name horizontal-scaling-sqs \
  --template-file "${SCRIPT_DIR}/horizontal-sqs-queues.yaml" \
  --region "${REGION}"

# 6. CloudFront CDN (depends on ALB DNS name)
echo "[6/7] Deploying CloudFront CDN..."
aws cloudformation deploy \
  --stack-name horizontal-scaling-cloudfront \
  --template-file "${SCRIPT_DIR}/horizontal-cloudfront.yaml" \
  --region "${REGION}" \
  --parameter-overrides \
      AlbDnsName="${ALB_DNS}" \
      WafWebAclArn="${WAF_ACL_ARN}"

# 7. Observability (depends on ASG name, ALB ARN, TG ARN)
echo "[7/7] Deploying observability (CloudWatch alarms)..."
ASG_NAME=$(aws cloudformation describe-stacks \
  --stack-name horizontal-scaling-asg \
  --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='AutoScalingGroupName'].OutputValue" \
  --output text)

aws cloudformation deploy \
  --stack-name horizontal-scaling-observability \
  --template-file "${SCRIPT_DIR}/horizontal-observability.yaml" \
  --region "${REGION}" \
  --parameter-overrides \
      OpsTeamEmail="${OPS_EMAIL}" \
      PagerDutyEndpoint="${PAGERDUTY_ENDPOINT}" \
      AsgName="${ASG_NAME}" \
      AlbArn="${ALB_ARN}" \
      TargetGroupArn="${TG_ARN}"

echo ""
echo "=== Horizontal scaling deployment complete ==="
echo ""
echo "Deployed stacks:"
echo "  horizontal-scaling-alb"
echo "  horizontal-scaling-asg"
echo "  horizontal-scaling-aurora"
echo "  horizontal-scaling-redis"
echo "  horizontal-scaling-sqs"
echo "  horizontal-scaling-cloudfront"
echo "  horizontal-scaling-observability"
