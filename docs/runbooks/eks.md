# Runbook: bring prod's EKS environment up, deploy the game, and tear it all down

- **Alert(s):** none yet. Monitoring comes with the observability stack. Until then, this runbook is the procedure, and its "What it means" table covers what goes wrong in it.
- **Service:** prod (ADRs 0046–0048):
  - `infra/live/prod/network` and `infra/live/prod/eks`;
  - the add-ons in `deploy/platform`;
  - the services in `deploy/apps` with `deploy/envs/prod`.
- **Severity:** page while players are on it, ticket otherwise
- **Last fired on purpose:** not yet; the first bring-up and teardown are recorded here with their dates.

Everything here changes AWS or the cluster, so a person runs it (CLAUDE.md rule 2), in WSL, from the repo root, with `aws login --profile rarebit` done. Two values come from `.mise.local.toml`, which git ignores:
- `RAREBIT_AWS_ACCOUNT_ID`;
- `RAREBIT_ADMIN_CIDR`, your own address as a `/32` (`curl -s https://checkip.amazonaws.com`). It's the only address the cluster's API answers.

**Cost while it's up:** about $0.25/h (`docs/cost.md`). That's the control plane, two t3.medium nodes, the NAT instance and its address, the ALB and the volumes. Tear it down when the session ends.

## What it means

| Symptom | What's wrong |
|---|---|
| `terragrunt apply` in `eks` fails with `RAREBIT_ADMIN_CIDR` | The variable isn't set, or isn't a `/32` |
| `kubectl` times out | Your address changed since the apply: set `RAREBIT_ADMIN_CIDR` again and apply `eks` (a few seconds) |
| No ALB appears (`kubectl get ingress` shows no address) | Read the LB controller's logs: `kubectl -n kube-system logs deploy/aws-load-balancer-controller`. Usually a missing subnet tag, or its Pod Identity role |
| Pods stuck `Pending` | `kubectl describe pod`: two t3.medium nodes are full, or a volume can't attach (the EBS CSI driver) |
| `validator-migrate` Job fails | Postgres isn't ready yet, or the Secret `rarebit-pg-app` doesn't exist: wait for the cluster, then delete the Job and upgrade the release again |
| The page loads but the game says it can't connect | `ALLOWED_ORIGINS` doesn't match the page's origin (step 9) |
| `terragrunt destroy` in `network` hangs on the VPC | Something the LB controller created is still there: an ALB, a target group, a security group (Teardown, step 2) |

## Impact on players

When it's down, there's no game at the link. A Redis restart ends the games in play; players start new ones.

## Bring up

1. **The network, then the cluster** (about 3 and 15 minutes). Read each plan before you answer `yes`:

   ```bash
   cd infra/live/prod/network && terragrunt apply && cd -
   cd infra/live/prod/eks && terragrunt apply && cd -
   ```

2. **kubectl:**

   ```bash
   aws eks update-kubeconfig --region eu-central-1 --name rarebit-prod
   kubectl get nodes   # two nodes, Ready
   ```

3. **The app namespace, before anything runs in it** (its labels only apply to pods created after them):

   ```bash
   kubectl apply -f deploy/platform/namespace.yaml
   ```

4. **The AWS Load Balancer Controller** (its role comes through Pod Identity):

   ```bash
   helm repo add eks https://aws.github.io/eks-charts && helm repo update eks
   helm install aws-load-balancer-controller eks/aws-load-balancer-controller --version 3.6.3 \
     --namespace kube-system -f deploy/platform/aws-load-balancer-controller/values.yaml \
     --set vpcId="$(cd infra/live/prod/network && terragrunt output -raw vpc_id)" --wait
   ```

5. **Postgres:** the operator, then the cluster. Wait until it's healthy:

   ```bash
   helm repo add cnpg https://cloudnative-pg.github.io/charts && helm repo update cnpg
   helm install cnpg cnpg/cloudnative-pg --version 0.29.2 --namespace cnpg-system --create-namespace \
     -f deploy/platform/cloudnative-pg/values.yaml --wait
   kubectl apply -f deploy/platform/postgres/cluster.yaml
   kubectl -n rarebit wait cluster/rarebit-pg --for=condition=Ready --timeout=10m
   ```

6. **Redis's password, and a placeholder for the game's origin.** The real origin comes in step 9:

   ```bash
   kubectl -n rarebit create secret generic redis --from-literal=password="$(openssl rand -hex 24)"
   kubectl -n rarebit create configmap game-origin --from-literal=origins=http://placeholder.invalid
   ```

7. **The images**, built from a `main` commit and pushed as `main-<sha7>`. This writes `deploy/envs/prod/*/image-tags.yaml`; commit those files:

   ```bash
   bash deploy/push-images.sh prod
   ```

8. **The services**, in this order: Redis, the migration (it waits for its Job), then the rest:

   ```bash
   reg="$RAREBIT_AWS_ACCOUNT_ID.dkr.ecr.eu-central-1.amazonaws.com"
   deploy() {  # deploy <service>: deploy/apps, then deploy/envs/prod if it has values for it
     local files=(-f "deploy/apps/$1/values.yaml")
     for f in values.yaml image-tags.yaml; do [ -f "deploy/envs/prod/$1/$f" ] && files+=(-f "deploy/envs/prod/$1/$f"); done
     helm upgrade --install "$1" deploy/charts/service -n rarebit "${files[@]}" --set image.registry="$reg" --wait --wait-for-jobs --timeout 15m
   }
   helm upgrade --install redis deploy/charts/service -n rarebit -f deploy/apps/redis/values.yaml --wait
   deploy validator-migrate && deploy validator && deploy game && deploy web
   ```

9. **The game's origin.** The ALB exists now. Point the game at its hostname, then restart it:

   ```bash
   alb="$(kubectl -n rarebit get ingress web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
   kubectl -n rarebit create configmap game-origin --from-literal=origins="http://$alb" --dry-run=client -o yaml | kubectl apply -f -
   kubectl -n rarebit rollout restart deploy/game && kubectl -n rarebit rollout status deploy/game
   echo "http://$alb"
   ```

## Verify

```bash
curl -fsS "http://$alb/" | grep -q 'id="root"' && echo "web UI: ok"
docker run --rm rarebit-bots:dev synthetic --url "http://$alb" --origin "http://$alb" --timeout 300   # make bots-image first
```

- The bots' verdict is `ok`.
- Open `http://$alb` on a phone and play a round.
- The web UI drains on SIGQUIT: `kubectl -n rarebit delete pod -l app.kubernetes.io/name=web --wait=false`, then `kubectl -n rarebit logs -l app.kubernetes.io/name=web -f`. After the 15 s pause, nginx logs a graceful shutdown.
- **The link is plain HTTP for now** (no domain or TLS yet, #45). Resume tokens and answers travel unencrypted, so share it only for testing.

## Tear down

The order matters. The LB controller created the ALB, its target groups and security groups, outside Terraform, so they have to go before the cluster and the VPC.

1. **The services, so the Ingresses go and the controller deletes the ALB:**

   ```bash
   helm -n rarebit uninstall web game validator validator-migrate redis
   ```

2. **Wait until the ALB and its target groups are gone.** Both commands must print nothing:

   ```bash
   aws elbv2 describe-load-balancers --region eu-central-1 --query "LoadBalancers[?starts_with(LoadBalancerName, 'k8s-rarebit')].LoadBalancerName" --output text
   aws elbv2 describe-target-groups --region eu-central-1 --query "TargetGroups[?starts_with(TargetGroupName, 'k8s-rarebit')].TargetGroupName" --output text
   ```

3. **Postgres, and its volume** (the volume is deleted with its claim). Then the controllers:

   ```bash
   kubectl delete -f deploy/platform/postgres/cluster.yaml --wait
   kubectl -n rarebit get pvc   # none left
   helm -n cnpg-system uninstall cnpg
   helm -n kube-system uninstall aws-load-balancer-controller
   ```

4. **The cluster, then the network:**

   ```bash
   cd infra/live/prod/eks && terragrunt destroy && cd -
   cd infra/live/prod/network && terragrunt destroy && cd -
   ```

5. **Leak check.** Each must print nothing:

   ```bash
   aws ec2 describe-volumes --region eu-central-1 --filters Name=tag:kubernetes.io/created-for/pvc/namespace,Values=rarebit --query 'Volumes[].VolumeId' --output text
   aws ec2 describe-addresses --region eu-central-1 --filters Name=tag:Project,Values=rarebit --query 'Addresses[].PublicIp' --output text
   aws eks list-clusters --region eu-central-1 --query 'clusters' --output text
   aws ec2 describe-vpcs --region eu-central-1 --filters Name=tag:Project,Values=rarebit --query 'Vpcs[].VpcId' --output text
   ```

## Roll back or escalate

- **A release that breaks:** `helm -n rarebit rollback <service>`, or run step 8 again with the previous `image-tags.yaml` from git.
- **A destroy stuck on the VPC:** find what's left with `aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=<vpc>`. It's usually an ALB's or the NAT instance's interface. Delete its owner, not the interface, then destroy again.

## Prevention

- `plat env up` and `plat env down` will run these steps in this order, with the waits and the leak check, and the nightly teardown will run `down`.
- Argo CD replaces steps 4 to 8 (ADR 0048).
- Until both exist, follow this runbook, and set no `KEEP_ALIVE_UNTIL`: nothing tears this down for you.
