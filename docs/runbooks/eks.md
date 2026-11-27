# Runbook: bring prod's EKS environment up, deploy the game, and tear it all down

- **Alert(s):** none yet. Monitoring comes with the observability stack. Until then, this runbook is the procedure, and its "What it means" table covers what goes wrong in it.
- **Service:** prod (ADRs 0046–0048):
  - `infra/live/prod/network` and `infra/live/prod/eks`;
  - the add-ons in `deploy/platform`;
  - the services in `deploy/apps` with `deploy/envs/prod`.
- **Severity:** page while players are on it, ticket otherwise
- **Last fired on purpose:** not yet; the first bring-up and teardown are recorded here with their dates.

Everything here changes AWS or the cluster, so a person runs it (CLAUDE.md rule 2), in WSL, from the repo root (mise sets `AWS_PROFILE=rarebit` there), with `aws login --profile rarebit` done. Two values come from `.mise.local.toml`, which git ignores:
- `RAREBIT_AWS_ACCOUNT_ID`;
- `RAREBIT_ADMIN_CIDR`, your own address as a `/32` (`curl -s https://checkip.amazonaws.com`). It's the only address the cluster's API answers.

**Cost while it's up:** about $0.26/h (`docs/cost.md`). That's the control plane, two t3.medium nodes, the NAT instance and the public addresses, the ALB and the volumes. Tear it down when the session ends.

## What it means

| Symptom | What's wrong |
|---|---|
| `terragrunt apply` in `eks` fails with `RAREBIT_ADMIN_CIDR` | The variable isn't set, or isn't a `/32` |
| `terragrunt` in `eks` fails with `prod/eks is not in private_state_units` | Someone took it out of `infra/live/_global/shared.hcl`: its state would become readable by pull request plans (ADR 0042) |
| The `eks` apply fails with an error about the account's plan | The account's plan doesn't allow it. Destroy the network at once (Tear down, step 5), so nothing bills |
| `kubectl` times out | Your address changed since the apply: set `RAREBIT_ADMIN_CIDR` again and apply `eks` (a few seconds) |
| Postgres's claim stays `Pending` | No default StorageClass: `kubectl get storageclass` must show `ebs-csi-default-sc (default)`, from the EBS CSI add-on's configuration |
| No ALB appears (`kubectl get ingress` shows no address) | Read the LB controller's logs: `kubectl -n kube-system logs deploy/aws-load-balancer-controller`. Usually a missing subnet tag, or its Pod Identity role |
| Pods stuck `Pending` | `kubectl describe pod`: two t3.medium nodes are full, or a volume can't attach (the EBS CSI driver) |
| `validator-migrate` Job fails | Postgres isn't ready yet, or the Secret `rarebit-pg-app` doesn't exist: wait for the cluster, then run step 9's `deploy validator-migrate` again |
| The page loads but the game says it can't connect | `ALLOWED_ORIGINS` doesn't match the page's origin (step 10) |
| `push-images.sh` fails part way | Run it again: images already pushed for that commit are kept, the rest are built |
| `terragrunt destroy` in `network` hangs on the VPC | Something the LB controller created is still there: an ALB, a target group, a security group (Tear down, step 2) |

## Impact on players

When it's down, there's no game at the link. A Redis restart ends the games in play; players start new ones.

## Bring up

0. **Once, before prod/eks's first apply,** and only if `_global/github-oidc` wasn't applied since `prod/eks` joined `private_state_units` (`infra/live/_global/shared.hcl`): apply it, so pull request plans can't read the cluster's state, or describe the cluster and its access entries (they hold your home address and IAM user, ADR 0042):

   ```bash
   cd infra/live/_global/github-oidc && terragrunt apply && cd -
   ```

   And every time, check who you are: `aws sts get-caller-identity` must show your user in the project account.

1. **The images first:** they need no cluster, so the cluster doesn't bill while they build. Built from a `main` commit and pushed as `main-<sha7>`. The script writes `deploy/envs/prod/*/image-tags.yaml`; commit those files on the pull request's branch:

   ```bash
   bash deploy/push-images.sh prod
   ```

2. **The network, then the cluster** (about 3 and 15 minutes). Read each plan before you answer `yes`:

   ```bash
   cd infra/live/prod/network && terragrunt apply && cd -
   cd infra/live/prod/eks && terragrunt apply && cd -
   ```

3. **kubectl:**

   ```bash
   aws eks update-kubeconfig --profile rarebit --region eu-central-1 --name rarebit-prod --alias rarebit-prod
   kubectl config use-context rarebit-prod
   kubectl get nodes          # two nodes, Ready
   kubectl get storageclass   # ebs-csi-default-sc (default)
   ```

4. **The app namespace, before anything runs in it** (its labels only apply to pods created after them):

   ```bash
   kubectl apply -f deploy/platform/namespace.yaml
   ```

5. **The AWS Load Balancer Controller** (its role comes through Pod Identity):

   ```bash
   helm repo add eks https://aws.github.io/eks-charts && helm repo update eks
   helm install aws-load-balancer-controller eks/aws-load-balancer-controller --version 3.6.3 \
     --namespace kube-system -f deploy/platform/aws-load-balancer-controller/values.yaml \
     --set vpcId="$(cd infra/live/prod/network && terragrunt output -raw vpc_id)" --wait
   ```

6. **Postgres:** the operator, then the cluster. Wait until it's healthy:

   ```bash
   helm repo add cnpg https://cloudnative-pg.github.io/charts && helm repo update cnpg
   helm install cnpg cnpg/cloudnative-pg --version 0.29.2 --namespace cnpg-system --create-namespace \
     -f deploy/platform/cloudnative-pg/values.yaml --wait
   kubectl apply -f deploy/platform/postgres/cluster.yaml
   kubectl -n rarebit wait cluster/rarebit-pg --for=condition=Ready --timeout=10m
   ```

7. **Redis's password, and a placeholder for the game's origin.** The real origin comes in step 10:

   ```bash
   kubectl -n rarebit create secret generic redis --from-literal=password="$(openssl rand -hex 24)"
   kubectl -n rarebit create configmap game-origin --from-literal=origins=http://placeholder.invalid
   ```

8. **A helper for the services:**

   ```bash
   reg="$RAREBIT_AWS_ACCOUNT_ID.dkr.ecr.eu-central-1.amazonaws.com"
   deploy() {  # deploy <service>: deploy/apps, then deploy/envs/prod where it has values for it
     local files=(-f "deploy/apps/$1/values.yaml") f
     for f in values.yaml image-tags.yaml; do [ -f "deploy/envs/prod/$1/$f" ] && files+=(-f "deploy/envs/prod/$1/$f"); done
     local sets=()
     [ "$1" = redis ] || sets+=(--set image.registry="$reg")
     helm upgrade --install "$1" deploy/charts/service -n rarebit "${files[@]}" "${sets[@]}" --wait --wait-for-jobs --timeout 15m
   }
   ```

9. **The services**, in this order: Redis, the migration (it waits for its Job), then the rest:

   ```bash
   deploy redis && deploy validator-migrate && deploy validator && deploy game && deploy web
   ```

10. **The game's origin.** The ALB exists now. Point the game at its hostname, then restart it:

    ```bash
    alb="$(kubectl -n rarebit get ingress web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
    kubectl -n rarebit create configmap game-origin --from-literal=origins="http://$alb" --dry-run=client -o yaml | kubectl apply -f -
    kubectl -n rarebit rollout restart deploy/game && kubectl -n rarebit rollout status deploy/game
    echo "http://$alb"
    ```

## Verify

```bash
curl -fsS "http://$alb/" | grep -q 'id="root"' && echo "web UI: ok"
make bots-image && docker run --rm rarebit-bots:dev synthetic --url "http://$alb" --origin "http://$alb" --timeout 300
```

- The bots' verdict is `ok`.
- Open `http://$alb` on a phone and play a round.
- The web UI drains on SIGQUIT: `kubectl -n rarebit delete pod -l app.kubernetes.io/name=web --wait=false`, then `kubectl -n rarebit logs -l app.kubernetes.io/name=web -f`. After the 15 s pause, nginx logs a graceful shutdown.
- **The link is plain HTTP for now** (no domain or TLS yet, #45). Resume tokens and answers travel unencrypted, so share it only for testing.

## Tear down

The order matters. The LB controller created the ALB, its target groups and security groups, and the EBS CSI driver Postgres's volume, all outside Terraform. They have to go while the controllers still run, before the cluster and the VPC.

1. **The services.** The Ingresses go with them, and the controller deletes the ALB:

   ```bash
   helm -n rarebit uninstall web game validator validator-migrate redis
   ```

2. **Wait until the ALB, its target groups and its security groups are gone.** Each must print nothing; run them again until they do:

   ```bash
   aws elbv2 describe-load-balancers --region eu-central-1 --query "LoadBalancers[?starts_with(LoadBalancerName, 'k8s-rarebit')].LoadBalancerName" --output text
   aws elbv2 describe-target-groups --region eu-central-1 --query "TargetGroups[?starts_with(TargetGroupName, 'k8s-')].TargetGroupName" --output text
   aws ec2 describe-security-groups --region eu-central-1 --filters Name=tag:elbv2.k8s.aws/cluster,Values=rarebit-prod --query 'SecurityGroups[].GroupId' --output text
   ```

3. **Postgres and its volume.** The volume is deleted with its claim, asynchronously: wait until no PersistentVolume is left. Then the controllers:

   ```bash
   kubectl delete -f deploy/platform/postgres/cluster.yaml --wait
   until [ -z "$(kubectl get pv -o name)" ]; do sleep 5; done
   helm -n cnpg-system uninstall cnpg
   helm -n kube-system uninstall aws-load-balancer-controller
   ```

4. **The cluster:**

   ```bash
   cd infra/live/prod/eks && terragrunt destroy && cd -
   ```

5. **The network:**

   ```bash
   cd infra/live/prod/network && terragrunt destroy && cd -
   ```

6. **Leak check.** Each must print nothing; the first must print the project account:

   ```bash
   aws sts get-caller-identity --query Account --output text
   aws eks list-clusters --region eu-central-1 --query 'clusters' --output text
   aws elbv2 describe-load-balancers --region eu-central-1 --query 'LoadBalancers[].LoadBalancerName' --output text
   aws ec2 describe-volumes --region eu-central-1 --filters Name=status,Values=available --query 'Volumes[].VolumeId' --output text
   aws ec2 describe-addresses --region eu-central-1 --query 'Addresses[].[PublicIp,AllocationId]' --output text
   aws ec2 describe-vpcs --region eu-central-1 --filters Name=tag:Project,Values=rarebit --query 'Vpcs[].VpcId' --output text
   ```

   If one prints something:
   - **a cluster or a VPC:** run its `destroy` again; Terraform still knows it;
   - **a load balancer** (and its target groups and security groups): `aws elbv2 delete-load-balancer --load-balancer-arn <arn>`, then the target groups, then the security groups;
   - **a volume:** `aws ec2 delete-volume --volume-id <id>`, once you're sure it's the cluster's (`kubernetes.io/created-for/pvc/name` tag);
   - **an address:** `aws ec2 release-address --allocation-id <id>`.

   Each of these deletes something: a person runs it (rule 2).

## Roll back or escalate

- **A release that breaks:** `helm -n rarebit rollback <service>`, or run step 9 again with the previous `image-tags.yaml` from git.
- **A destroy stuck on the VPC:** find what's left with `aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=<vpc>`. It's usually an ALB's or the NAT instance's interface. Delete its owner, not the interface, then destroy again.

## Prevention

- `plat env up` and `plat env down` will run these steps in this order, with the waits and the leak check, and the nightly teardown will run `down`.
- Argo CD replaces steps 4 to 10 (ADR 0048).
- Until both exist, follow this runbook, and set no `KEEP_ALIVE_UNTIL`: nothing tears this down for you.
