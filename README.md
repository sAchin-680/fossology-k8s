# FOSSology on Kubernetes — Proof of Concept

A working Kubernetes deployment of [FOSSology](https://github.com/fossology/fossology) on a local [kind](https://kind.sigs.k8s.io/) cluster, demonstrating:

- **Web UI** accessible via port-forward
- **Scheduler** (`fo_scheduler`) running and dispatching scan jobs
- **Agent worker pods** running separately from the scheduler, receiving work via **SSH over the Kubernetes pod network**
- **License scans completing end-to-end** against a PostgreSQL database

---

## Architecture

<p align="center">
  <img src="docs/fossology_k8s_architecture.svg" alt="FOSSology K8s Architecture" width="800"/>
</p>

| Component                   | K8s Resource                    | Role                                                        |
| --------------------------- | ------------------------------- | ----------------------------------------------------------- |
| **fossology-web**           | Deployment + ClusterIP Service  | Apache/PHP UI on port 80                                    |
| **fossology-scheduler**     | Deployment                      | `fo_scheduler` — reads `[HOSTS]`, dispatches agents via SSH |
| **fossology-workers-{0,1}** | StatefulSet + Headless Service  | `sshd` + all FOSSology agents; receive work from scheduler  |
| **postgres**                | StatefulSet + ClusterIP Service | PostgreSQL database                                         |
| **fossology-repo**          | PersistentVolumeClaim (RWX)     | Shared repository storage across web, scheduler, workers    |

The scheduler uses FOSSology's built-in SSH dispatch mechanism. For each host listed in `[HOSTS]`, it forks and calls:

```c
// agent.c — simplified
args[0] = "/usr/bin/ssh";
args[1] = host->address;   // fossology-workers-0.fossology-workers.fossology.svc.cluster.local
args[2] = agent_binary_cmd;
execv(args[0], args);
```

Workers are a `StatefulSet` so they get stable DNS names (required for the `[HOSTS]` config). A headless Service resolves worker FQDNs directly to pod IPs.

---

## Proof of Concept — Evidence

### 1. All pods running with separate IPs

The scheduler, web, and worker pods each run in their own pod with distinct IPs — workers are fully separate from the scheduler:

```
$ kubectl get pods -n fossology -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,IP:.status.podIP,RESTARTS:.status.containerStatuses[0].restartCount"

NAME                                   STATUS    IP            RESTARTS
fossology-scheduler-7d9d59f9b8-rhxxb   Running   10.244.0.24   2
fossology-web-6fbdc6b6c4-vkpns         Running   10.244.0.20   0
fossology-workers-0                    Running   10.244.0.26   0
fossology-workers-1                    Running   10.244.0.25   0
postgres-0                             Running   10.244.0.4    1
```

<p align="center">
  <img src="docs/screenshots/pods-running.png" alt="All pods running" width="750"/>
</p>

### 2. SSH dispatch — scheduler to worker pods

The scheduler dispatches agents to workers over SSH using the Kubernetes pod network. The `fossy` user on the scheduler can SSH into both workers:

```
$ kubectl exec deployment/fossology-scheduler -n fossology -- \
    su -s /bin/sh fossy -c "ssh fossy@fossology-workers-0...svc.cluster.local echo SSH_OK"
SSH_OK_WORKER_0

$ kubectl exec deployment/fossology-scheduler -n fossology -- \
    su -s /bin/sh fossy -c "ssh fossy@fossology-workers-1...svc.cluster.local echo SSH_OK"
SSH_OK_WORKER_1
```

The `[HOSTS]` section in `fossology.conf` contains **only remote workers** (no localhost), so all agent work is dispatched over SSH:

```ini
[HOSTS]
fossology-workers-0 = fossology-workers-0.fossology-workers.fossology.svc.cluster.local /usr/local/etc/fossology 4
fossology-workers-1 = fossology-workers-1.fossology-workers.fossology.svc.cluster.local /usr/local/etc/fossology 4
```

<p align="center">
  <img src="docs/screenshots/ssh-dispatch.png" alt="SSH dispatch to workers" width="750"/>
</p>

### 3. Web UI — scans completing

The FOSSology web UI is accessible at `http://localhost:8080/repo` via port-forward. Uploads are scanned by agents dispatched to worker pods, and license findings (GPL-2.0-only, LGPL-2.1-only, etc.) appear in the license browser:

<p align="center">
  <img src="docs/screenshots/web-ui.png" alt="FOSSology Web UI with scan results" width="750"/>
</p>

---

## Repository Structure

```
fossology-k8s/
├── docs/
│   ├── fossology_k8s_architecture.svg   # Architecture diagram
│   └── screenshots/                     # PoC evidence screenshots
├── images/
│   └── worker/
│       └── Dockerfile                   # fossology base + sshd
├── manifests/
│   ├── namespace.yaml
│   ├── configmap.yaml                   # Db.conf, fossology.conf ([HOSTS])
│   ├── shared-pvc.yaml                  # RWX PVC for repository
│   ├── postgres.yaml                    # StatefulSet + Service
│   ├── web.yaml                         # Deployment + Service (port 80)
│   ├── scheduler.yaml                   # Deployment + init container (SSH setup)
│   └── worker-statefulset.yaml          # StatefulSet + headless Service (port 22)
└── scripts/
    └── bootstrap.sh                     # One-command cluster setup
```

## Quick Start

### Prerequisites

- [kind](https://kind.sigs.k8s.io/) and `kubectl`
- Docker Desktop (or equivalent)

### 1. Create the kind cluster

```bash
kind create cluster --name fossology-poc
```

### 2. Bootstrap everything

```bash
./scripts/bootstrap.sh
```

This single command:

1. Generates an ED25519 SSH keypair (gitignored, never committed)
2. Creates the `fossology-ssh-keys` Kubernetes Secret
3. Builds and loads the `fossology-worker` image into kind
4. Applies all manifests in dependency order and waits for rollout

### 3. Access the UI

```bash
kubectl port-forward svc/fossology-web 8080:80 -n fossology
```

Open http://localhost:8080/repo — log in with `fossy` / `fossy`.

### 4. Verify SSH dispatch

```bash
kubectl exec deployment/fossology-scheduler -n fossology -- \
  su -s /bin/sh fossy -c \
  "ssh fossy@fossology-workers-0.fossology-workers.fossology.svc.cluster.local echo OK"
```

---

## Key Design Decisions

| Decision                                         | Reason                                                                              |
| ------------------------------------------------ | ----------------------------------------------------------------------------------- |
| `StatefulSet` for workers                        | Stable DNS names required for `[HOSTS]` entries                                     |
| Headless `Service` for workers                   | DNS resolves directly to pod IPs, no VIP                                            |
| `emptyDir` + init container for `fossology.conf` | Entrypoint uses `sed -i` (atomic rename), which fails on read-only ConfigMap mounts |
| Worker `ENTRYPOINT []`                           | Base `docker-entrypoint.sh` rewrites `Db.conf` on start — fails on ConfigMap mount  |
| `StrictModes no` in `sshd_config`                | K8s Secret-mounted `authorized_keys` is root-owned                                  |
| No localhost in `[HOSTS]`                        | Forces all agent dispatch to remote worker pods                                     |

## Security

- SSH keypair is **gitignored** — regenerate with `ssh-keygen -t ed25519 -f worker-key -N ""`
- `PasswordAuthentication no` enforced — only pubkey auth accepted on workers
- For production: store keys in Vault / SealedSecrets instead of `bootstrap.sh` local keygen

## License

GPL-2.0-only — consistent with [FOSSology](https://github.com/fossology/fossology/blob/master/LICENSE).
