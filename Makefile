TF := terraform
INFRA_DIR := terraform/infra
K8S_DIR := terraform/kubernetes
SCRIPTS_DIR := scripts
NAMESPACE ?= bioinformatics
KUBECONFIG ?= $(HOME)/.kube/config-hcl-public-netflow
RUN_ID ?=
INPUT ?=
OUTDIR ?=
RESUME ?= 0
SAVE_ALIGN_INTERMEDS ?= false
GEN3_SCRATCH_BENCHMARK ?= 0
NF_ARGS ?=

KUBECONFIG_ARG := -var="kubeconfig_path=$(KUBECONFIG)"
export KUBECONFIG

.PHONY: help infra-init infra-plan infra-apply kubeconfig platform-init platform-plan \
	platform-apply sync-secret plan fmt validate shell-syntax status outputs \
	bootstrap-reference run-pipeline destroy deploy run

help: ## List available workflows
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "\033[36m%-24s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

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
	bash $(SCRIPTS_DIR)/sync-k8s-secret.sh

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
	@set -eu; for script in $(SCRIPTS_DIR)/*.sh; do bash -n "$$script"; done

status: ## Show cluster nodes and Nextflow jobs
	kubectl get nodes -o wide
	kubectl get pvc -n $(NAMESPACE)
	kubectl get jobs,pods -n $(NAMESPACE) -o wide

bootstrap-reference:
	bash $(SCRIPTS_DIR)/bootstrap-reference.sh

run-pipeline:
	@test -n "$(RUN_ID)" || { echo 'Set RUN_ID to a unique run name.'; exit 2; }
	bash $(SCRIPTS_DIR)/run-pipeline.sh "$(RUN_ID)" $(if $(INPUT),--input "$(INPUT)",) $(if $(OUTDIR),--outdir "$(OUTDIR)",) $(if $(filter 1 true,$(GEN3_SCRATCH_BENCHMARK)),--gen3-scratch-benchmark,) $(if $(filter 1 true,$(RESUME)),--resume,) -- --save_align_intermeds $(SAVE_ALIGN_INTERMEDS) $(NF_ARGS)

deploy: ## Create the cluster and install the Nextflow platform
	$(MAKE) infra-apply
	$(MAKE) kubeconfig
	$(MAKE) platform-apply
	$(MAKE) sync-secret

run: ## Run a synthetic or real samplesheet already stored in Object Storage
	@test -n "$(RUN_ID)" || { echo 'Set RUN_ID to a unique run name.'; exit 2; }
	@test -n "$(INPUT)" || { echo 'Set INPUT to s3://bucket/path/samplesheet.csv.'; exit 2; }
	$(MAKE) bootstrap-reference
	$(MAKE) run-pipeline RUN_ID="$(RUN_ID)" INPUT="$(INPUT)" OUTDIR="$(OUTDIR)" RESUME="$(RESUME)" SAVE_ALIGN_INTERMEDS="$(SAVE_ALIGN_INTERMEDS)" GEN3_SCRATCH_BENCHMARK="$(GEN3_SCRATCH_BENCHMARK)" NF_ARGS="$(NF_ARGS)"

destroy: ## Destroy Kubernetes and Scaleway resources (interactive)
	$(TF) -chdir=$(K8S_DIR) destroy -var-file=terraform.tfvars $(KUBECONFIG_ARG)
	$(TF) -chdir=$(INFRA_DIR) destroy -var-file=terraform.tfvars
