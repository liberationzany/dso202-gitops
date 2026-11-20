<!--
File       : README.md
Assignment : DSO202 Assignment 4
Descriptor : Unit IV 4.1-4.4 (GitOps with Argo CD), reusing 1.2.5, 1.5.1,
             1.5.3, 2.1, 2.3, 3.1.4 and 3.2
Purpose    : What this repository is, how to build the whole environment from
             an empty machine, how credentials are handled, and the written
             answers Q1-Q6.
-->
# dso202-gitops — GitOps delivery of the Task Tracker with Argo CD

The Task Tracker from Assignments 1–3 (nginx frontend, Express backend,
PostgreSQL StatefulSet) is delivered by **Argo CD**, which runs in the cluster,
reads this repository and makes the cluster match it. After the two bootstrap
steps, nothing is deployed by a person: a release is a commit, recovery is a
`git revert`, and the whole environment can be rebuilt from this repository
plus one backed-up key (done in Task 9: 44 s from the root Application to a
working dev environment).

| Environment | Namespace | Application follows | Sync | Reach it |
|---|---|---|---|---|
| dev | `dso202-dev` | branch `main` | automated, prune, self-heal | <http://localhost:30080> (API on 30082) |
| staging | `dso202-staging` | tag `v1.2.0` (now) | **manual** (the promotion gate) | port-forwards to 8081 / 8082 |

Evidence for every task: [`docs/evidence.md`](docs/evidence.md).

## Pinned versions

| Component | Version |
|---|---|
| Argo CD (server and CLI) | **v3.5.6** — `bootstrap/argocd/kustomization.yaml` pins `.../argo-cd/v3.5.6/manifests/install.yaml` |
| Sealed Secrets Helm chart | **2.20.0** (`argocd/applications/sealed-secrets.yaml`) |
| Sealed Secrets controller / `kubeseal` | **0.40.0** |
| kind / node image / kubectl | v0.32.0 / `kindest/node:v1.36.1@sha256:3489c767…` / v1.36.3 (as Practical 1) |
| Helm | v4.3.1 (as Assignment 3) |
| Application images | `local/dso202-{frontend,backend,db}` tags **1.0** and **1.1** only (see *Deviations*) |

No file uses `latest`, `stable`, `master` or `HEAD` as a version.

## Repository layout

```
dso202-gitops/
├── .gitignore                    # first commit: keys and plaintext Secrets never enter Git
├── cluster/kind-cluster.yaml     # Practical 1's cluster (renamed; dev API port 30082 added)
├── bootstrap/                    # applied BY HAND, once per cluster
│   ├── argocd/                   # pinned upstream install + argocd-cm / argocd-rbac-cm patches
│   └── root/                     # platform AppProject + root Application (app of apps)
├── argocd/                       # watched by the root Application
│   ├── projects/dso202.yaml      # least-privilege workload project
│   └── applications/             # sealed-secrets, platform-dev/-staging, tasktracker-dev/-staging
├── platform/{dev,staging}/       # namespace (Prune=false), quota+limits, RBAC, SealedSecret
├── charts/tasktracker/           # Assignment 3 chart, adjusted to contract C1-C11
├── environments/{dev,staging}/values.yaml   # everything that differs per environment
└── docs/                         # evidence.md + screenshots/
```

Sync waves through the root: `dso202` project (−3) → Sealed Secrets (−2) →
platform-dev/-staging (−1) → workloads (0); inside the chart: database (0) →
backend (1) → frontend (2) → smoke-test Job (PostSync).

## Building everything from an empty machine

This is the sequence practised in Task 9. Prerequisites: Docker, kind,
kubectl, Helm, `kubeseal`, and the sealing-key backup
(`../dso202-keys/sealing-key.backup.yaml`, **not** in this repository).

```bash
git clone https://github.com/liberationzany/dso202-gitops.git && cd dso202-gitops

# 1. Cluster (host ports 30080 and 30082 must be free)
kind create cluster --name dso202-gitops --config cluster/kind-cluster.yaml

# 2. Application images. The stand-in images are local only (see Deviations);
#    build them from the course repository, then load them into kind.
#      DSO202/assignment4/stand-in-images/build.sh
kind load docker-image local/dso202-frontend:1.0 local/dso202-frontend:1.1 \
  local/dso202-backend:1.0 local/dso202-backend:1.1 local/dso202-db:1.0 --name dso202-gitops

# 3. Restore the sealing key BEFORE the controller exists
kubectl create namespace sealed-secrets
kubectl apply -f ../dso202-keys/sealing-key.backup.yaml

# 4. Bootstrap: Argo CD, then the root Application. Nothing else by hand.
kubectl apply -k bootstrap/argocd --server-side --force-conflicts
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=600s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
kubectl apply -f bootstrap/root
kubectl get applications -n argocd -w          # waves -3 .. 0; dev serves on :30080

# 5. Sign in and open the staging gate once (staging is manual by design)
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
argocd admin initial-password -n argocd
argocd login localhost:8080 --username admin --insecure
argocd app sync tasktracker-staging

# 6. Staging from the host
kubectl port-forward -n dso202-staging svc/tasktracker-frontend 8081:8080 &
kubectl port-forward -n dso202-staging svc/tasktracker-backend  8082:8080 &

# 7. Back up the key again (the controller may have added one)
kubectl get secret -n sealed-secrets -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > ../dso202-keys/sealing-key.backup.yaml
```

The `reviewer` account (Task 6) exists after bootstrap, but its password lives
in `argocd-secret`, which a rebuild regenerates: set it again with
`argocd account update-password --account reviewer`.

## Cleanup

```bash
kind delete cluster --name dso202-gitops      # everything, including the database volumes
# The key backup stays in ../dso202-keys; delete it only if the SealedSecrets
# in Git will never be needed again (they become undecryptable).
```

Never `kubectl delete application root` on a cluster you want to keep: its
finalizer deletes every child Application and, through theirs, every workload.

## How credentials are handled

1. `.gitignore` (the first commit) excludes `secrets-plain/`, `*.key`,
   `*sealing-key*` and `*.backup.yaml`.
2. Per environment, the four values (`DB_USER`/`POSTGRES_USER` equal,
   `DB_PASSWORD`/`POSTGRES_PASSWORD` equal; dev and staging differ) were
   generated into a git-ignored `secrets-plain/<env>.env`, readable only by
   the owner, without ever appearing on a command line.
3. `kubectl create secret … --dry-run=client -o yaml | kubeseal --format yaml`
   encrypted them in the pipe with the controller's public key; only the
   `SealedSecret` (`platform/<env>/tasktracker-credentials.sealed.yaml`) was
   committed. Strict scope: name and namespace are part of the ciphertext.
4. The plaintext files were deleted. `git log -p --all -S"<value>"` for every
   value returned nothing (Task 4, values never printed).
5. The controller's private key is backed up **outside the repository and
   outside the OneDrive-synced Desktop** (`C:\Users\zeroe\dso202-keys`,
   owner-only ACL), and re-backed-up after the rebuild.
6. The chart never renders a Secret; Pods read `tasktracker-credentials`
   (`existingSecret`), which the controller creates from the SealedSecret.

## Deviations from the brief

| Brief | Done instead | Why |
|---|---|---|
| Images `<tutor>/dso202-*:1.0` and `:1.1` from Docker Hub | Local stand-ins `local/dso202-*:1.0/1.1`, built in the course repo (`DSO202/assignment4/stand-in-images/`), kind-loaded, never pushed | On 2026-11-19 the tutor's repositories had **only tag 1.0, only linux/arm64** (this machine is amd64; same as Assignment 1); 1.1 did not exist. 1.0 = the Assignment 1 images; 1.1 implements exactly the release notes — frontend header shows the release; backend refactors config loading and (undocumented) requires `APP_ENV`, which is the Task 7 fault. |
| Delete the old `dso202` cluster | Stopped, auto-restart disabled (`docker update --restart=no`) | It holds Practicals 1–6 and Assignments 1–3; stopped containers do not hold port 30080. |
| `cluster/kind-cluster.yaml` copied from Practical 1 | Renamed; **host port 30082 added** | The given frontend has no `/api` proxy — the browser calls `BACKEND_URL` directly (Assignment 1) — and no ingress controller is installed, so the dev API needs a host-reachable port. Staging uses port-forwards 8081/8082. |
| ResourceQuota/LimitRange "from Assignment 2" | From Practical 1 (`01-quota-and-limits.yaml`), resized | Assignment 2 had no quota or limit range. Role/RoleBinding are Assignment 2's. |
| Whitelist = exactly the rendered kinds | + `ReplicaSet`, `Pod` (commented) | Argo CD v3.5.6 applies the project whitelist to the **resource tree** too: without them no Pods appeared, and no account could read logs (Task 6). |
| `argocd` CLI on the host | The same v3.5.6 CLI from the `argocd-server` image, run in that Pod | The Windows build downloaded at ~25 KB/s and twice arrived with a wrong SHA-256; it was not installed. |
| Images pulled by the nodes | Pre-loaded from saved archives (`docker save --platform linux/amd64` + `kind load image-archive`) | Slow link; plain `kind load` fails on multi-arch images in Docker Desktop's containerd store. |

## Written answers

### Q1 — Why is `platform` applied by hand while `dso202` comes from the root, and what if `dso202` could deploy into `argocd`?

The root Application needs a project to live in before it can exist, so the
project that owns it must already be there: `platform` is part of the
bootstrap, applied once with `kubectl apply -f bootstrap/root`. It is also
the administrator-level project (any cluster-scoped kind, the `argocd`
namespace), and keeping its definition out of the root means no commit to
`argocd/` can widen it. `dso202` is an ordinary, narrow project, so it is
created *by* the root like any other file (Task 3: tracking id
`root:argoproj.io/AppProject:argocd/dso202`) and changes only through Git —
as it did in Task 6. If `dso202` could deploy into `argocd`, any commit to the
chart could create an `Application` or `AppProject` there — for example one in
the `platform` project pointing at an arbitrary path — and so obtain
cluster-wide rights: administrator capability for anyone who can merge to the
chart.

### Q2 — What does strict scope prevent, and what happens if the sealing key is lost?

Strict scope makes the SealedSecret's name and namespace part of what is
encrypted. It prevents a sealed value from being *reused*: copying the dev
file into `dso202-staging`, or renaming it, gives a ciphertext the controller
refuses to decrypt — so someone who can commit to one namespace cannot
replay another environment's credentials there. If the sealing key is lost,
every SealedSecret in Git is permanently undecryptable (the private key exists
nowhere else and cannot be regenerated); the Secrets already in a running
cluster keep working until it is rebuilt. What must be done: let the new
controller generate a key, obtain the plaintext values again (password
manager, or read them from a still-running cluster), re-seal every secret for
every namespace, commit, and take a new backup — and, if the values cannot be
recovered, rotate the database passwords. Task 9 showed the opposite case: with
the backup restored first, the platform Applications were Healthy within
seconds.

### Q3 — Synced vs Healthy

*Synced* compares desired and live **configuration** ("is what Git says
applied?"); *Healthy* assesses whether the applied objects **work** (Pods
ready, rollout complete). They are independent. Example from Task 7: after
the faulty backend release dev showed

```
Sync Status:        Synced to main (98ea4e5)
Health Status:      Degraded
apps  Deployment  dso202-dev  tasktracker-backend  Synced  Degraded  Deployment "tasktracker-backend" exceeded its progress deadline
```

— Git was applied exactly, but the new Pod crash-looped. The reverse was seen
in Task 8, Drill 2: staging was *OutOfSync* (3 live replicas vs 1 in Git) yet
*Healthy*. Observation for the brief's expectation in Task 5: before the first
staging sync the root reported **Healthy** while its child
`tasktracker-staging` was *Missing* — in v3.5.6 a child's *Missing* did not
lower the root's aggregate, whereas *Progressing* and *Degraded* did.

### Q4 — Argo CD RBAC vs Kubernetes RBAC; what SSO would change

**Argo CD RBAC** (`argocd-rbac-cm`, `policy.csv`) controls what a user of the
Argo CD API/UI/CLI may do with *Argo CD objects*: view, sync, delete or read
logs of Applications, per project (`dso202/*`). The `reviewer` could `get`
applications but not `sync`, and could read logs only after one more line.
**Kubernetes RBAC** (Role/RoleBinding in `platform/<env>/rbac.yaml`, from
Assignment 2) controls what a Kubernetes identity may do with *cluster
objects* through the API server. They are separate: Argo CD itself acts with
its own ServiceAccounts, so a reviewer who may `sync` changes the cluster
without holding any Kubernetes permission, and a user with `kubectl` rights
needs no Argo CD account. With SSO (Dex/OIDC), users and **groups** come from
the identity provider: `accounts.reviewer` would be dropped and the policy
would bind groups, e.g. `g, dso202-reviewers, role:dso202-reader` with
`p, role:dso202-reader, applications, get, dso202/*, allow` (and the `logs`
line), so access follows group membership instead of local passwords.

### Q5 — Why was `argocd app rollback` refused, what is the GitOps equivalent, and why revert rather than delete history?

It printed `FailedPrecondition: rollback cannot be initiated when auto-sync is
enabled`. A rollback would deploy an older revision while Git still declares
the new one; with automated sync the next reconciliation would immediately
re-apply Git and undo it, so Argo CD refuses. The GitOps equivalent is a new
commit that restores the desired state — `git revert 98ea4e5` (PR #4) — which
the cluster then follows like any release. `git revert` is preferred to
deleting the commit because history is the audit trail and the shared
contract: removing a pushed commit rewrites `main` under everyone else (a
force push), hides what was deployed and when, and the bad commit remains
reachable through tags, forks and caches anyway. Two observations from this
run: the failed release's sync operation kept **retrying for ~7.5 minutes**
(retry limit 5) and blocked the revert from being applied until it gave up —
`argocd app terminate-op` would have shortened that; and staging never ran the
faulty backend (`argocd app history tasktracker-staging`: v1.0.0, v1.1.0,
v1.2.0).

### Q6 — (a) One repository: two advantages, two disadvantages

Advantages: (1) a chart change and the values that use it land in **one
atomic commit and one tag** — `v1.2.0` pins both the chart and the staging
values, so staging can never get a chart from one moment and values from
another; (2) one place to review, clone and rebuild from — Task 9 needed one
`git clone` and one key. Disadvantages: (1) every commit to `main` is seen by
every dev Application — a chart refactor and a config tweak share one
history and one review path, and anyone who may change values may also change
templates; (2) the tags mix two meanings (application release and
configuration snapshot), and as the system grows the Argo CD repo-server
re-renders on unrelated commits; separate repositories allow separate access
control (developers on the chart, operators on environment config).

### Q6 — (b) What is not under GitOps control after the rebuild, and how teams handle it

- **The bootstrap layer** (`bootstrap/argocd`, including `argocd-rbac-cm` —
  the Task 6 change needed a manual `kubectl apply`): teams let Argo CD manage
  its own installation (a self-managing Application) or install it with
  Terraform/a cluster-provisioning pipeline from the same pinned files.
- **The root Application and `platform` project**: created by the same
  provisioning automation (or a cluster bootstrap tool such as Flux/argocd
  autopilot), so the one manual step is scripted and versioned.
- **The sealing key**: kept in a secrets manager or HSM-backed vault and
  restored by automation — or avoided by using an external secret store
  (External Secrets Operator with Vault/cloud KMS) so no cluster-specific key
  exists.
- **The database contents**: backed up separately — scheduled `pg_dump` or
  volume snapshots to object storage, or a Postgres operator with continuous
  WAL archiving (Unit II 2.4) — and restored as a separate step; Git describes
  the database server, not its data.
- **Other runtime state**: the Argo CD admin password and the `reviewer`
  password (regenerated by the rebuild), and Argo CD's sync history — handled
  by SSO and by treating Git history as the record.

## Bonus

### Task 10 (bonus) — chart and values from separate sources

`tasktracker-dev` is a two-source Application (PR #7): source 1 renders the
chart, source 2 (`ref: values`, no path) supplies
`$values/environments/dev/values.yaml`. Both follow `main`, so nothing in the
cluster changed (no rollout; evidence, Task 10). Separating the sources is useful when the chart and the configuration move
at different speeds or belong to different people. For example, a platform
team can pin the chart to a reviewed release tag (`targetRevision: v1.2.0` on
source 1) while the values source keeps following `main`. Dev then gets every
configuration change - a replica count, a new `APP_ENV` - as soon as it
merges, but never an untested template change; a chart upgrade becomes one
deliberate edit to source 1. The same split lets the values live in a
separate configuration repository with its own access rules, which is the
separation the Argo CD best-practice guide recommends (Q6a), without copying
the chart into it.

