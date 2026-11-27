# 0046. Each environment's VPC: two zones, public and private subnets, a NAT instance instead of a NAT Gateway

- **Status:** accepted
- **Date:** 2026-11-27
- **Deciders:** platform owner

## Context

- The cluster's nodes and pods need outbound internet: image pulls (ECR, Docker Hub, GitHub's registry), AWS APIs, and the game's own egress. Nothing on the internet may reach them directly.
- A NAT Gateway costs $0.052/h in eu-central-1, plus $0.052 per GB processed (AWS Price List API, 2026-11-27); a t4g.nano, $0.0048/h (2026-11-23). That's a fifth of the whole environment's hourly cost, and CLAUDE.md rule 6 rules it out.
- An ALB needs subnets in at least two availability zones, and so does EKS.
- With the VPC CNI, every pod takes a VPC address (prefix delegation takes 16 at a time).
- The environment is torn down at the end of every session, so a short NAT outage costs a session minutes, not players hours.

## Decision

**`infra/modules/network`:** one VPC per environment, a /16, across two zones.

- **Public subnets** (a /24 each) hold the ALB and the NAT instance. The subnets themselves hand out no public IPs. The ALB has its own addresses, and the NAT instance its Elastic IP, plus the public address fck-nat's launch template gives it. They're tagged `kubernetes.io/role/elb` for the AWS Load Balancer Controller.
- **Private subnets** (a /20 each) hold the nodes and the pods. They're tagged `kubernetes.io/role/internal-elb`, and `karpenter.sh/discovery` for later.
- **Routes:** the public route table sends `0.0.0.0/0` to the internet gateway. The private one sends it through the NAT instance.
- **The NAT instance is fck-nat** (`RaJiska/fck-nat` 1.6.1, its AMI pinned: `fck-nat-al2023-hvm-1.4.0-20261109-arm64-ebs`, not whatever was published last) on a t4g.nano, in an Auto Scaling group of one that replaces it when it fails. Its static network interface keeps the Elastic IP and the private route across a replacement. It allows no SSH; Session Manager is the way in if ever needed.
- **The VPC's default security group has no rules,** so anything put in it by mistake gets no traffic.
- **An S3 gateway endpoint** (free) on the private route table, so ECR's image layers, which are stored in S3, skip the NAT instance.
- **No interface endpoints:** at $0.012/h per zone each (Price List API, 2026-11-27), they would cost more than the NAT instance.

## Alternatives considered

| Option | Why not |
|---|---|
| A NAT Gateway | $0.052/h plus $0.052/GB: about $38/month if it stayed up, against about $3.50 for a t4g.nano. Rule 6 |
| A NAT Gateway per zone (the HA setup) | Twice that |
| Public subnets for the nodes, no NAT | Every node would get a public address and face the internet; only the security groups would stand between them and it |
| Interface endpoints for ECR, STS and the rest instead of NAT | $0.012/h per endpoint per zone, several of them, and Docker Hub and GitHub would still need a way out |

## Consequences

- **Good:**
  - outbound internet for about $0.005/h, plus its address ($0.005/h);
  - image layers from ECR don't go through it at all.
- **Bad / risks:**
  - **One instance in one zone is a single point of failure for outbound traffic.** While the ASG replaces it (a few minutes), pods can't pull new images or reach the internet. Running pods keep serving players, since inbound goes through the ALB.
  - **A t4g.nano is a small, burstable instance** with modest network bandwidth: enough for image pulls and the game's egress, not for heavy downloads. A larger t4g type is one variable away.
  - **Patching:** the instance runs the pinned fck-nat AMI; a newer one comes only by changing `nat_ami_id`. Nothing patches a running one.
- **Follow-ups:** none for now. A NAT Gateway per zone is the answer if the environment ever stays up for players.

## How we'll know it was right

- Image pulls and the game's outbound calls work through it.
- The monthly bill shows no NAT Gateway line.
- If the NAT instance fails during a session more than once, reconsider a second one in the other zone.
