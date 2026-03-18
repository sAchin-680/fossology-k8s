# SPDX-FileCopyrightText: © 2026 FOSSology Contributors
# SPDX-License-Identifier: GPL-2.0-only
#
# Makefile — developer-friendly targets for the fossology-k8s PoC.
#
# Quick start:
#   make up        — creates kind cluster, builds images, deploys everything
#   make test      — runs end-to-end smoke test
#   make down      — tears down the cluster
#
.DEFAULT_GOAL := help
.PHONY: up down test test-ssh test-dns status build load keys deploy wait \
        logs-scheduler logs-worker logs-web check-conf clean test-data \
        port-forward cluster help

CLUSTER   ?= fossology-poc
NAMESPACE ?= fossology
IMAGE     ?= fossology-worker:poc

# Registry address used in manifests — override if your kind network differs
REGISTRY  ?= 172.19.0.3:5000

# ── Full lifecycle ──────────────────────────────────────────────────────────

up: cluster build load keys deploy wait   ## Create cluster, build, deploy, wait
	@echo ""
	@echo "  FOSSology is ready."
	@echo "  Run:  make port-forward"
	@echo "  Then: http://localhost:8080/repo  (fossy / fossy)"

down:                                     ## Tear down the kind cluster
	@bash scripts/teardown.sh

clean: down                               ## Tear down + remove generated files
	rm -f worker-key worker-key.pub
	rm -rf test-data/

# ── Individual steps ────────────────────────────────────────────────────────

cluster:                                  ## Create the kind cluster
	@if kind get clusters 2>/dev/null | grep -q "^$(CLUSTER)$$"; then \
		echo "[skip] Cluster '$(CLUSTER)' already exists"; \
	else \
		kind create cluster --config kind-config.yaml --name $(CLUSTER); \
	fi

build:                                    ## Build the worker Docker image
	docker build --platform linux/amd64 --provenance=false \
		--output type=docker -t $(IMAGE) images/worker/

load: build                               ## Load images into kind
	kind load docker-image $(IMAGE) --name $(CLUSTER)
	@docker pull fossology/fossology:latest 2>/dev/null || true
	kind load docker-image fossology/fossology:latest --name $(CLUSTER)

keys:                                     ## Generate SSH keypair + K8s Secret
	@bash scripts/generate-keys.sh

deploy:                                   ## Apply all Kubernetes manifests
	@kubectl apply -f manifests/namespace.yaml
	@sleep 1
	@kubectl apply -f manifests/configmap.yaml
	@kubectl apply -f manifests/shared-pvc.yaml
	@kubectl apply -f manifests/networkpolicy.yaml
	@kubectl apply -f manifests/postgres.yaml
	@kubectl apply -f manifests/web.yaml
	@kubectl apply -f manifests/scheduler.yaml
	@kubectl apply -f manifests/worker-statefulset.yaml
	@kubectl apply -f manifests/hpa-workers.yaml 2>/dev/null || \
		echo "[info] HPA skipped (metrics-server not available)"

wait:                                     ## Wait for all pods to be ready
	@bash scripts/wait-for-ready.sh

# ── Testing ─────────────────────────────────────────────────────────────────

test: test-data                           ## Run end-to-end smoke test
	@bash scripts/smoke-test.sh

test-ssh:                                 ## Verify SSH from scheduler → workers
	@echo "── SSH to worker-0 ──"
	@kubectl exec deployment/fossology-scheduler -n $(NAMESPACE) -- \
		su -s /bin/sh fossy -c \
		"ssh fossy@fossology-workers-0.fossology-workers.$(NAMESPACE).svc.cluster.local hostname" \
		2>/dev/null && echo "OK" || echo "FAILED"
	@echo "── SSH to worker-1 ──"
	@kubectl exec deployment/fossology-scheduler -n $(NAMESPACE) -- \
		su -s /bin/sh fossy -c \
		"ssh fossy@fossology-workers-1.fossology-workers.$(NAMESPACE).svc.cluster.local hostname" \
		2>/dev/null && echo "OK" || echo "FAILED"

test-dns:                                 ## Check worker DNS resolution
	@kubectl exec deployment/fossology-scheduler -n $(NAMESPACE) -- \
		nslookup fossology-workers-0.fossology-workers.$(NAMESPACE).svc.cluster.local

test-data:                                ## Generate test data tarball
	@bash scripts/generate-test-data.sh

# ── Diagnostics ─────────────────────────────────────────────────────────────

status:                                   ## Show pod status
	@kubectl get pods -n $(NAMESPACE) -o wide

port-forward:                             ## Forward web UI to localhost:8080
	kubectl port-forward svc/fossology-web 8080:80 -n $(NAMESPACE)

logs-scheduler:                           ## Tail scheduler logs
	kubectl logs -f deployment/fossology-scheduler -n $(NAMESPACE)

logs-worker:                              ## Tail worker-0 logs
	kubectl logs -f statefulset/fossology-workers -n $(NAMESPACE)

logs-web:                                 ## Tail web logs
	kubectl logs -f deployment/fossology-web -n $(NAMESPACE)

check-conf:                               ## Show [HOSTS] from scheduler's fossology.conf
	@kubectl exec deployment/fossology-scheduler -n $(NAMESPACE) -- \
		grep -A5 '\[HOSTS\]' /usr/local/etc/fossology/fossology.conf

help:                                     ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
