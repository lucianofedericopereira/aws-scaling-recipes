# AWS Scaling Recipes — Makefile
# Unified command interface for both scaling recipes.
#
# Usage:
#   make check          Verify prerequisites
#   make deploy-vertical
#   make deploy-horizontal
#   make deploy-both
#   make validate       Validate all CloudFormation templates (requires cfn-lint)
#   make lint-shell     Lint all shell scripts (requires shellcheck)
#   make lint           Run all linters (cfn-lint + shellcheck)
#   make destroy        Delete all stacks (with confirmation)
#   make help           Show this help

.PHONY: help check deploy-vertical deploy-horizontal deploy-both validate lint-shell lint destroy

help:
	@echo "AWS Scaling Recipes"
	@echo ""
	@echo "  make check              Verify prerequisites (AWS CLI, credentials, config.env)"
	@echo "  make deploy-vertical    Deploy vertical scaling recipe (6 CF stacks)"
	@echo "  make deploy-horizontal  Deploy horizontal scaling recipe (7 CF stacks)"
	@echo "  make deploy-both        Deploy both recipes"
	@echo "  make validate           Validate all CloudFormation templates with cfn-lint"
	@echo "  make lint-shell         Lint all shell scripts with shellcheck"
	@echo "  make lint               Run all linters"
	@echo "  make destroy            Delete all stacks (interactive confirmation)"

check:
	@bash deploy.sh check

deploy-vertical:
	@bash deploy.sh vertical

deploy-horizontal:
	@bash deploy.sh horizontal

deploy-both:
	@bash deploy.sh both

validate:
	@echo "=== Validating CloudFormation templates ==="
	@command -v cfn-lint >/dev/null 2>&1 || { echo "cfn-lint not found. Install: pip install cfn-lint"; exit 1; }
	@cfn-lint Vertical/vertical-s3-sqs-pipeline.yaml
	@cfn-lint Vertical/vertical-ebs-volumes.yaml
	@cfn-lint Vertical/vertical-ec2-strategy.yaml
	@cfn-lint Vertical/vertical-rds-scaling.yaml
	@cfn-lint Vertical/vertical-batch-overflow.yaml
	@cfn-lint Vertical/vertical-cloudwatch.yaml
	@cfn-lint Horizontal/horizontal-alb-config.yaml
	@cfn-lint Horizontal/horizontal-asg-config.yaml
	@cfn-lint Horizontal/horizontal-aurora-serverless.yaml
	@cfn-lint Horizontal/horizontal-elasticache-redis.yaml
	@cfn-lint Horizontal/horizontal-sqs-queues.yaml
	@cfn-lint Horizontal/horizontal-cloudfront.yaml
	@cfn-lint Horizontal/horizontal-observability.yaml
	@echo "All templates passed cfn-lint."

lint-shell:
	@echo "=== Linting shell scripts ==="
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck not found. Install: apt install shellcheck / brew install shellcheck"; exit 1; }
	@shellcheck deploy.sh main.sh Vertical/launch_vertical.sh Horizontal/launch_horizontal.sh
	@echo "All shell scripts passed shellcheck."

lint: validate lint-shell
	@echo "=== All linters passed ==="

destroy:
	@bash deploy.sh destroy
