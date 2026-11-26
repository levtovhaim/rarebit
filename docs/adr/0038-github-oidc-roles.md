# 0038. GitHub Actions reaches AWS through OIDC, with one role per kind of job, trusted by exact claims

- **Status:** accepted
- **Date:** 2026-11-26
- **Deciders:** platform owner

## Context

- CLAUDE.md rule 5: CI reaches AWS only through GitHub OIDC, and no static keys exist.
- **Every GitHub Actions run can get a token** signed by `token.actions.githubusercontent.com`, if its workflow grants `permissions: id-token: write`. The token's claims say where the run comes from:
  - `aud`, the audience (`sts.amazonaws.com` for AWS);
  - `sub`:
    - `repo:<owner>/<name>:pull_request` for pull requests;
    - `repo:<owner>/<name>:ref:refs/heads/main` for pushes to main;
    - `repo:<owner>/<name>:environment:<env>` for a job that names an environment.
- STS trades a valid token for a role's credentials (`AssumeRoleWithWebIdentity`) when the role's trust policy accepts its claims.
- **Pull requests from branches of this repository get tokens; pull requests from forks don't.** Agents open PRs from branches here, and a pull request runs the workflow from its own branch, so a PR job runs code nobody has reviewed yet.
- IAM can limit ECR pushes by repository but not by tag, so ADR 0036 split main and PR images into separate repositories, and left this PR to say who may push to which.

## Decision

- **An IAM OIDC provider** for GitHub's issuer, with the audience `sts.amazonaws.com`. No thumbprint: AWS checks the issuer's certificate against its own trusted CAs.
- **One role per kind of job,** under the IAM path `/ci/`, with one-hour sessions. Each role's trust policy accepts one exact `sub` and the `aud`, with `StringEquals` only: no `StringLike`, no wildcards.

  | Role | Trusted `sub` | What it may do |
  |---|---|---|
  | `gha-ci-pr` | `repo:levtovhaim/rarebit:pull_request` | push, read and delete images in `rarebit/pr/*` |
  | `gha-ci-main` | `repo:levtovhaim/rarebit:ref:refs/heads/main` | push and read images in the main repositories; no delete |
  | `gha-tf-plan` | `repo:levtovhaim/rarebit:pull_request` | read everything (`ReadOnlyAccess`) and write state lock objects; an explicit deny on reading secret values (SSM parameters, Secrets Manager, KMS decrypt) and on any other account's buckets |

- **No CI role may change IAM,** repository policies, lifecycle rules, tag mutability, scanning or replication, or use a `*` action. The module's tests check this.
- **The main repositories enforce the split themselves.** Their repository policies deny pushes by anyone but `gha-ci-main` and IAM users (people, as break-glass), and deny deleting images to everyone but IAM users. The PR repositories take pushes and deletes from `gha-ci-pr` and IAM users. The policies only deny, and only requests made by a principal, so lifecycle expiry isn't touched.
- **The roles' and repositories' names live in one file,** `infra/live/_global/shared.hcl`, read by both units. The repository policies name the roles by ARN, built from those names, so neither unit depends on the other's outputs.
- **No apply or teardown role yet.** Those roles change real infrastructure. They come with their workflows, behind GitHub environments with a required reviewer, trusted by `environment:<env>`.

## Alternatives considered

| Option | Why not |
|---|---|
| An IAM user's access key in a GitHub secret | A long-lived secret that every workflow, and every PR job, could read |
| One CI role for every job | A pull request job would get main's rights: it could push a `main-` image |
| `StringLike` with `repo:levtovhaim/rarebit:*` | Any run of the repository, any event, could take the role |
| Trusting `ref:refs/heads/*` for the main role | Any branch, so any PR's branch pushed by its author, could act as main |
| Customizing the `sub` claim to include the repository ID | Guards against a deleted repository's name being taken over. Worth it later; it's a GitHub repository setting, and every trust policy changes with it |
| `ViewOnlyAccess` plus a hand-written list for the plan role | Narrower, but a plan's refresh reads attributes `ViewOnlyAccess` doesn't cover; the explicit denies take away what matters most (secret values) |

## Consequences

- **Good:**
  - no key exists to leak;
  - a pull request can't act as main, by trust policy, IAM policy and repository policy;
  - a credential lives one hour.
- **Bad / risks:**
  - **The trust is only as exact as the `sub`.** A job that names an `environment:` gets the environment's `sub`, not `pull_request` or `ref:…`. So PR and main jobs don't use environments, and apply jobs will.
  - **Merge queue runs** (`ref:refs/heads/gh-readonly-queue/main/…`) match neither role. That's by design: main images are pushed after the merge, by main's run.
  - **`ReadOnlyAccess` is broad for code from a pull request.** It still reads every resource's configuration. The bucket-side allowlist for state is a follow-up (#62).
  - **Renaming the repository breaks every trust policy:** `shared.hcl` changes with it.
- **Follow-ups (#62):**
  - the apply and teardown roles with their environments;
  - `-lock-timeout` for applies;
  - the state bucket's allowlist;
  - the node role (pull-only) with the cluster.

## How we'll know it was right

- A pull request run takes `gha-ci-pr`, pushes to `rarebit/pr/<service>`, and its push to `rarebit/<service>` fails with `explicit deny in a resource-based policy`.
- A run on main takes `gha-ci-main`; a pull request run trying `gha-ci-main` fails with `Not authorized to perform sts:AssumeRoleWithWebIdentity`.
- IAM Access Analyzer finds nothing in the role policies (checked on 2026-11-26).
