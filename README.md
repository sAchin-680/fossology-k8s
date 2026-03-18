# FOSSology on Kubernetes — PoC

Kubernetes deployment of [FOSSology](https://github.com/fossology/fossology), demonstrating the scheduler's SSH-based distributed agent dispatch across worker pods.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                   fossology namespace                    │
│                                                         │
│  ┌──────────┐    port 80     ┌─────────────────────┐   │
│  │  fossology│◄──────────────│   fossology-web      │   │
│  │  -web     │               │ (Apache + PHP UI)    │   │
│  └──────────┘                └──────────┬──────────┘   │
│                                         │ port 24693    │
│                               ┌─────────▼──────────┐   │
│                               │ fossology-scheduler │   │
│                               │  (fo_scheduler)     │   │
│                               └──┬──────────────┬──┘   │
│                    SSH port 22   │              │       │
│                   ┌──────────────▼──┐  ┌────────▼────┐ │
│                   │ workers-0 (sshd)│  │workers-1    │ │
│                   │  + fo agents    │  │(sshd+agents)│ │
│                   └─────────────────┘  └─────────────┘ │
│                                                         │
│  ┌─────────┐   ┌──────────────────┐                    │
│  │postgres │   │  fossology-repo  │  (shared PVC)      │
│  │StatefulS│   │  PersistentVolume│                    │
│  └─────────┘   └──────────────────┘                    │
└─────────────────────────────────────────────────────────┘
```

The scheduler uses FOSSology's built-in SSH dispatch (`/usr/bin/ssh <worker-fqdn> <agent-cmd>`) to distribute scan jobs. Each worker pod runs `sshd` and has all FOSSology agents installed — identical to the `fossology/fossology` base image, plus `openssh-server`.

## Repository structure

```
fossology-k8s/
├── images/
│   └── worker/
│       └── Dockerfile          # fossology base + sshd; ENTRYPOINT cleared
├── manifests/
│   ├── namespace.yaml
│   ├── configmap.yaml          # Db.conf, fossology.conf ([HOSTS] with workers)
│   ├── shared-pvc.yaml         # RWX PVC shared by web, scheduler, workers
│   ├── postgres.yaml           # StatefulSet + headless Service
│   ├── web.yaml                # Deployment + Service (port 80)
│   ├── scheduler.yaml          # Deployment with init container for SSH setup
│   └── worker-statefulset.yaml # StatefulSet + headless Service (port 22)
└── scripts/
    └── bootstrap.sh            # Full cluster setup: keygen → secret → build → apply
```

## Quick start

### Prerequisites

- [kind](https://kind.sigs.k8s.io/) and `kubectl`
- Docker Desktop (or equivalent)
- A local registry accessible at `localhost:5001` (see below)

### 1. Create the kind cluster with a local registry

```bash
# Create registry container
docker run -d --restart=always -p 5001:5000 --name kind-registry registry:2

# Create kind cluster (connects it to the registry network)
kind create cluster --name fossology-poc

# Connect registry to kind network
docker network connect kind kind-registry
```

### 2. Bootstrap everything

```bash
./scripts/bootstrap.sh
```

This single command:
1. Generates an ED25519 SSH keypair (`worker-key` / `worker-key.pub`) — **gitignored, never committed**
2. Creates the `fossology-ssh-keys` Kubernetes Secret from the keypair
3. Builds and pushes the `fossology-worker` image to the local registry
4. Applies all manifests in dependency order and waits for rollout

### 3. Access the UI

```bash
kubectl port-forward svc/fossology-web 8080:80 -n fossology
# Open http://localhost:8080/repo  (admin / admin)
```

## SSH dispatch — how it works

FOSSology's `fo_scheduler` reads `[HOSTS]` from `fossology.conf`. For non-localhost entries it forks:

```c
// agent.c — simplified
args[0] = "/usr/bin/ssh";
args[1] = host->address;   // e.g. fossology-workers-0.fossology-workers.fossology.svc.cluster.local
args[2] = agent_binary_cmd;
execv(args[0], args);
```

The scheduler calls `setuid(fossy/999)` before this fork, so the SSH key must be owned by `fossy` with mode `0600`. Since Kubernetes Secret mounts are root-owned, the `setup-scheduler` init container handles this by copying the key into an `emptyDir` and `chown`ing it appropriately.

## Key design decisions

| Decision | Reason |
|---|---|
| `StatefulSet` for workers | Stable pod DNS names required for `[HOSTS]` entries |
| Headless `Service` for workers | DNS resolves directly to pod IPs, no VIP |
| `emptyDir` + init container for `fossology.conf` | The entrypoint uses `sed -i` (atomic rename), which fails on read-only ConfigMap `subPath` mounts |
| Worker `ENTRYPOINT []` | Base `docker-entrypoint.sh` rewrites `Db.conf` on start — fails when it is ConfigMap-mounted read-only |
| `StrictModes no` in `sshd_config` | K8s Secret-mounted `authorized_keys` is root-owned; `StrictModes no` lets `sshd` accept it |

## Security notes

- The SSH keypair is **gitignored**. Regenerate with `ssh-keygen -t ed25519 -f worker-key -N ""`.
- For production: store the private key in Vault / AWS Secrets Manager / SealedSecrets and remove `scripts/bootstrap.sh`'s local keygen step.
- `PasswordAuthentication no` is enforced in `sshd_config` — only pubkey auth is accepted.
- `worker-key` appears in early git history; rotate the keypair and force-push or use `git filter-repo` before making this repository public.

## License

GPL-2.0-only — consistent with the [FOSSology project](https://github.com/fossology/fossology/blob/master/LICENSE).
