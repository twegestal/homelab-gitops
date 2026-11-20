CLUSTER       := homelab
GITHUB_OWNER  ?= twegestal
GITHUB_REPO   ?= homelab-gitops
CLUSTER_PATH  := clusters/homelab
COLIMA_CPU    ?= 4
COLIMA_MEMORY ?= 8

.DEFAULT_GOAL := help
.PHONY: help tools up down destroy bootstrap status reconcile

help: ## Show available commands
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

tools: ## Check that required CLI tools are installed
	@for t in colima docker kubectl k3d helm flux; do \
		command -v $$t >/dev/null 2>&1 && echo "✔ $$t" || { echo "✗ $$t is missing"; exit 1; }; \
	done

up: tools ## Start Colima and create or start the cluster
	@colima status >/dev/null 2>&1 || colima start --cpu $(COLIMA_CPU) --memory $(COLIMA_MEMORY)
	@if k3d cluster list $(CLUSTER) >/dev/null 2>&1; then \
		k3d cluster start $(CLUSTER); \
	else \
		k3d cluster create --config k3d.yaml; \
		echo "New cluster created. Run 'make bootstrap' to install Flux."; \
	fi
	@kubectl get nodes

down: ## Stop the cluster and Colima (keeps all state)
	-k3d cluster stop $(CLUSTER)
	-colima stop

destroy: ## Delete the cluster completely
	k3d cluster delete $(CLUSTER)

bootstrap: ## Install Flux and connect it to this repo (needs GITHUB_TOKEN)
	@test -n "$$GITHUB_TOKEN" || { echo "Set GITHUB_TOKEN first: read -s GITHUB_TOKEN && export GITHUB_TOKEN"; exit 1; }
	flux check --pre
	flux bootstrap github \
		--owner=$(GITHUB_OWNER) \
		--repository=$(GITHUB_REPO) \
		--branch=main \
		--path=$(CLUSTER_PATH) \
		--personal \
		--private=false

status: ## Show cluster and Flux status
	@kubectl get nodes
	@echo
	@flux get kustomizations
	@echo
	@flux get helmreleases -A

reconcile: ## Make Flux sync from Git right now
	flux reconcile kustomization flux-system --with-source
