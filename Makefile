TF := terraform
INFRA_DIR := terraform/infra
K8S_DIR := terraform/kubernetes
NAMESPACE ?= bioinformatics
KUBECONFIG ?= $(HOME)/.kube/config-hcl-public-netflow
KUBECONFIG_ARG := -var="kubeconfig_path=$(KUBECONFIG)"
export KUBECONFIG

.PHONY: help infra-init infra-plan infra-apply kubeconfig platform-init platform-plan \
	platform-apply sync-secret plan outputs fmt validate shell-syntax status reference run deploy destroy

help: ## List available workflows
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "\033[36m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

infra-init:
	$(TF) -chdir=$(INFRA_DIR) init -input=false -backend-config=backend.hcl

infra-plan: infra-init
	$(TF) -chdir=$(INFRA_DIR) plan -input=false -var-file=terraform.tfvars

infra-apply: infra-init
	$(TF) -chdir=$(INFRA_DIR) apply -var-file=terraform.tfvars

kubeconfig:
	@mkdir -p "$$(dirname "$(KUBECONFIG)")"
	@cluster_id=$$($(TF) -chdir=$(INFRA_DIR) output -raw cluster_id) && \
	region=$$($(TF) -chdir=$(INFRA_DIR) output -raw region) && \
	scw k8s kubeconfig install "$$cluster_id" region="$$region"
	@kubectl get nodes -o wide

platform-init:
	$(TF) -chdir=$(K8S_DIR) init -input=false -backend-config=backend.hcl

platform-plan: platform-init
	$(TF) -chdir=$(K8S_DIR) plan -input=false -var-file=terraform.tfvars $(KUBECONFIG_ARG)

platform-apply: platform-init
	$(TF) -chdir=$(K8S_DIR) apply -var-file=terraform.tfvars $(KUBECONFIG_ARG)

sync-secret:
	bash scripts/sync-k8s-secret.sh

plan: ## Review the infrastructure plan
	$(MAKE) infra-plan

outputs: ## Show bucket names and cluster details
	$(TF) -chdir=$(INFRA_DIR) output

fmt:
	$(TF) fmt -recursive

validate:
	@set -eu; for dir in $(INFRA_DIR) $(K8S_DIR); do \
		$(TF) -chdir=$$dir init -backend=false -input=false; \
		$(TF) -chdir=$$dir validate; \
	done

shell-syntax:
	@set -eu; for script in scripts/*.sh kubernetes/base/*.sh; do bash -n "$$script"; done

status: ## Show cluster nodes, volumes and jobs
	kubectl get nodes -o wide
	kubectl get pvc -n $(NAMESPACE)
	kubectl get jobs,pods -n $(NAMESPACE) -o wide

reference: ## Start the reference installation job
	kubectl apply -k kubernetes/reference

run: ## Start the Nextflow job configured in kubernetes/run/run.env
	kubectl apply -k kubernetes/run

deploy: ## Create the cluster and install the Nextflow platform
	$(MAKE) infra-apply
	$(MAKE) kubeconfig
	$(MAKE) platform-apply
	$(MAKE) sync-secret

destroy: ## Destroy Kubernetes and Scaleway resources (interactive)
	$(TF) -chdir=$(K8S_DIR) destroy -var-file=terraform.tfvars $(KUBECONFIG_ARG)
	$(TF) -chdir=$(INFRA_DIR) destroy -var-file=terraform.tfvars
