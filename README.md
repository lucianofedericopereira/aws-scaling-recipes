# AWS Scaling Recipes

**Author:** Luciano Federico Pereira  
**Purpose:** Real-world AWS scaling patterns from production experience  

## Vertical Scaling

### Architecture

```
Client → S3 (incoming PDFs) → SQS → EC2 processing nodes → S3 (output) → On-premise print server
                                          |
                                    AWS Batch (overflow)
```

### EC2 Vertical Scaling Path

| Workload | Initial | Scaled | Trigger |
|----------|---------|--------|--------|
| PDF flattening | `c5.large` (2 vCPU, 4 GB) | `c5.4xlarge` (16 vCPU, 32 GB) | CPU > 80% sustained |
| Imposition | `m5.xlarge` (4 vCPU, 16 GB) | `m5.8xlarge` (32 vCPU, 128 GB) | Memory > 75% or swap |
| Rasterization | `i3.large` (2 vCPU, 15 GB NVMe) | `i3.4xlarge` (16 vCPU, 122 GB NVMe) | EBS IOPS saturation or I/O wait > 20% |

### Stacks (in deploy order)

1. `buschi-s3-sqs-pipeline` — S3 buckets + SQS job queue (DLQ after 3 failures)
2. `buschi-ebs-volumes` — io1 (RIP server), gp2 (prepress temp), sc1 (job archive)
3. `buschi-ec2-strategy` — three EC2 instances at initial sizes
4. `buschi-rds-scaling` — RDS PostgreSQL db.m4.large, io1 3000 IOPS
5. `buschi-aws-batch` — overflow compute (scales 0 → 64 vCPU)
6. `buschi-cloudwatch` — alarms for EC2 CPU, RDS IOPS, SQS depth and age

### Deploy

```bash
# 1. Store DB password in SSM Parameter Store
aws ssm put-parameter \
  --name /buschi/db-password \
  --value 'YourSecurePassword' \
  --type SecureString

# 2. Edit configuration variables at the top of launch_buschi.sh
#    (REGION, KEY_NAME, VPC_ID, SUBNET_ID, DB_SUBNET_IDS, OPS_EMAIL)

# 3. Deploy
./launch_buschi.sh
```

---

## Horizontal Scaling

### Architecture

```
                    CloudFront CDN
                    (static assets + WAF)
                          |
                    ALB (Layer 7)
                          |
              ┌───────────┼───────────┐
              │           │           │
           EC2 #1      EC2 #2      EC2 #N    ← ASG (min: 2, max: 20)
              │           │           │
              └───────────┼───────────┘
                          |
         ┌────────────────┼────────────────┐
         │                │                │
   Aurora Serverless  ElastiCache      SQS Queues
   v2 (2–64 ACU)      Redis            (orders, inventory,
   + RDS Proxy        (session, cache,  notifications)
   + 2 read replicas   rate limit, cart)
```

### Stacks (in deploy order)

1. `noblex-alb-config` — ALB with HTTPS termination, TLS 1.3, health checks
2. `noblex-asg-config` — ASG with CPU target tracking, request count tracking, scheduled pre-warm
3. `noblex-aurora-serverless` — Aurora Serverless v2, 2 read replicas, RDS Proxy
4. `noblex-elasticache-redis` — Redis primary + replica, encrypted at rest and in transit
5. `noblex-sqs-queues` — FIFO order queue, Standard queues for inventory and notifications
6. `noblex-cloudfront` — CDN offloads ~60–70% of origin load during peak
7. `noblex-observability` — alarms for 5xx spikes (PagerDuty), latency, ASG headroom, Aurora ACU

### Deploy

```bash
# 1. Store DB password in SSM Parameter Store
aws ssm put-parameter \
  --name /noblex/db-password \
  --value 'YourSecurePassword' \
  --type SecureString

# 2. Edit configuration variables at the top of launch_noblex.sh
#    (VPC_ID, subnet IDs, CERTIFICATE_ARN, WAF_ACL_ARN, OPS_EMAIL, PAGERDUTY_ENDPOINT)

# 3. Deploy
./launch_noblex.sh
```

### Key Scaling Decisions

| Concern | Solution | Rationale |
|---------|----------|-----------|
| Unpredictable traffic | ASG (2–20 × c5.xlarge) + pre-warm schedule | Scale in/out elastically; pre-warm before known promotion start |
| Database spikes | Aurora Serverless v2 (2–64 ACU) | Pay per ACU-second; no manual intervention during flash sale |
| Connection storms on scale-out | RDS Proxy | Pools connections so 20 new instances don't overwhelm Aurora |
| Read-heavy product browsing | 2 read replicas + Redis cache | Distribute SELECTs; Redis cuts ~70% of Aurora read load |
| Slow synchronous processing | SQS async queues | Decouple payment path from receipt generation, email, inventory sync |
| Static asset bandwidth | CloudFront CDN | Offloads 60–70% of origin load; product images served from edge |
| DDoS / traffic abuse | WAF Web ACL on CloudFront | Rate limiting and rule-based blocking before traffic hits origin |

---

## Vertical vs. Horizontal: Decision Matrix

| Factor | Vertical (Buschi) | Horizontal (Noblex) |
|--------|-------------------|---------------------|
| Traffic pattern | Steady, predictable growth | Explosive, unpredictable spikes |
| Failure tolerance | Single point of failure | Fault tolerant (multi-AZ ASG) |
| Scaling ceiling | Largest available instance | Virtually unlimited |
| Cost model | Fixed (always paying for peak) | Elastic (scale in after peak) |
| Complexity | Low — just resize the instance | High — ALB, ASG, queues, CDN |
| Re-architecture needed? | No — monolithic app unchanged | Yes — stateless app, async processing |
| Application constraint | Monolithic/legacy OK | Must be stateless |
| Best for | Industrial tools, batch workloads, hybrid on-premise/cloud | Consumer-facing, viral campaigns, API services |

---

## Prerequisites

- AWS CLI v2 configured with IAM credentials that have permissions to create EC2, RDS, SQS, S3, CloudFormation, ElastiCache, CloudFront, and CloudWatch resources
- An existing VPC with public and private subnets across at least 2 AZs
- An ACM certificate (for Noblex HTTPS)
- A WAF Web ACL in `us-east-1` (for Horizontal CloudFront)
- EC2 Key Pairs for SSH access

---

## Notes

- **Placeholder values** (`vpc-REPLACE_ME`, `subnet-REPLACE_ME`, etc.) in the launch scripts must be updated before deploying.
- **Passwords** are read from SSM Parameter Store at deploy time — never hardcode credentials.
- The `buschi-aws-batch.yaml` stack references an ECR image (`buschi-print:latest`) that must be built and pushed before the Batch job definition can run.
- The Horizontal scheduled scaling actions (`promo-warmup`, `promo-cooldown`) are set to October 2022 dates. Update the cron expressions for future use.
