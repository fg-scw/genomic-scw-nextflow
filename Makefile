TF := terraform
INFRA_DIR := terraform/infra
K8S_DIR := terraform/kubernetes
SCRIPTS_DIR := scripts
NAMESPACE ?= bioinformatics
KUBECONFIG ?= $(HOME)/.kube/config-hcl-public-netflow
STATE_BUCKET ?=
STATE_PROJECT_ID ?= 1d6906b8-42b0-4141-8752-28b7fcfccb95
STATE_REGION ?= fr-par
RUN_ID ?=
RESUME ?= 0
AUTO_APPROVE ?= 0
NF_ARGS ?=

APPLY_FLAG := $(if $(filter 1 true,$(AUTO_APPROVE)),-auto-approve,)
KUBECONFIG_ARG := -var="kubeconfig_path=$(KUBECONFIG)"
export KUBECONFIG

.PHONY: help bootstrap-state init infra-init infra-plan infra-apply kubeconfig platform-init platform-plan \
	platform-apply sync-secret cluster plan fmt validate shell-syntax status outputs \
	bootstrap-reference prepare-demo run-pipeline validate-run smoke-test deploy-and-validate \
	destroy

help: ## List available workflows
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "\033[36m%-24s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

init: ## Bootstrap the backend bucket then initialize both Terraform roots
	$(MAKE) bootstrap-state STATE_BUCKET=$(STATE_BUCKET) STATE_PROJECT_ID=$(STATE_PROJECT_ID) STATE_REGION=$(STATE_REGION)
	$(MAKE) infra-init
	$(MAKE) platform-init

bootstrap-state: ## Create a private versioned state bucket before Terraform init
	@test -n "$(STATE_BUCKET)" || { printf 'Set STATE_BUCKET to the dedicated Terraform state bucket name.\n' >&2; exit 2; }
	@test -n "$(STATE_PROJECT_ID)" || { printf 'Set STATE_PROJECT_ID to the Scaleway project UUID for the state bucket.\n' >&2; exit 2; }
	@printf '%s\n' "$(STATE_PROJECT_ID)" | grep -Eq '^[0-9a-fA-F-]{36}$$' || { printf 'STATE_PROJECT_ID must be a UUID.\n' >&2; exit 2; }
	@if scw object bucket get "$(STATE_BUCKET)" project-id="$(STATE_PROJECT_ID)" region="$(STATE_REGION)" >/dev/null 2>&1; then \
	  printf 'State bucket already exists: %s\n' "$(STATE_BUCKET)"; \
	else \
	  printf 'Creating private, versioned state bucket %s in project %s.\n' "$(STATE_BUCKET)" "$(STATE_PROJECT_ID)"; \
	  scw object bucket create "$(STATE_BUCKET)" enable-versioning=true acl=private project-id="$(STATE_PROJECT_ID)" region="$(STATE_REGION)"; \
	fi
	@status=$$(aws --endpoint-url "https://s3.$(STATE_REGION).scw.cloud" --region "$(STATE_REGION)" \
	  s3api get-bucket-versioning --bucket "$(STATE_BUCKET)" --query Status --output text 2>/dev/null || true); \
	if [ "$$status" != Enabled ]; then \
	  aws --endpoint-url "https://s3.$(STATE_REGION).scw.cloud" --region "$(STATE_REGION)" \
	    s3api put-bucket-versioning --bucket "$(STATE_BUCKET)" \
	    --versioning-configuration Status=Enabled; \
	fi
	@status=$$(aws --endpoint-url "https://s3.$(STATE_REGION).scw.cloud" --region "$(STATE_REGION)" \
	  s3api get-bucket-versioning --bucket "$(STATE_BUCKET)" --query Status --output text) && \
	  test "$$status" = Enabled || { printf 'Versioning is not enabled for state bucket %s.\n' "$(STATE_BUCKET)" >&2; exit 1; }
	@printf 'State bucket ready: %s (%s, versioning enabled)\n' "$(STATE_BUCKET)" "$(STATE_REGION)"

infra-init: ## Initialize the Scaleway infrastructure Terraform root
	$(TF) -chdir=$(INFRA_DIR) init -input=false -backend-config=backend.hcl

infra-plan: infra-init ## Review the infrastructure plan
	$(TF) -chdir=$(INFRA_DIR) plan -input=false -var-file=terraform.tfvars

infra-apply: infra-init ## Apply the infrastructure plan
	$(TF) -chdir=$(INFRA_DIR) apply -input=false -var-file=terraform.tfvars $(APPLY_FLAG)

kubeconfig: ## Install the cluster kubeconfig at $(KUBECONFIG)
	@mkdir -p "$$(dirname "$(KUBECONFIG)")"
	@cluster_id=$$($(TF) -chdir=$(INFRA_DIR) output -raw cluster_id) && \
	region=$$($(TF) -chdir=$(INFRA_DIR) output -raw region) && \
	scw k8s kubeconfig install "$$cluster_id" region="$$region"
	@kubectl get nodes -o wide

platform-init: ## Initialize the Kubernetes resources Terraform root
	$(TF) -chdir=$(K8S_DIR) init -input=false -backend-config=backend.hcl

platform-plan: platform-init ## Review the Kubernetes resources plan
	$(TF) -chdir=$(K8S_DIR) plan -input=false -var-file=terraform.tfvars $(KUBECONFIG_ARG)

platform-apply: platform-init ## Apply namespace, RBAC, PVCs and pipeline configuration
	$(TF) -chdir=$(K8S_DIR) apply -input=false -var-file=terraform.tfvars $(KUBECONFIG_ARG) $(APPLY_FLAG)

sync-secret: ## Copy the pipeline S3 secret from Scaleway Secret Manager into Kubernetes
	bash $(SCRIPTS_DIR)/sync-k8s-secret.sh

cluster: ## Deploy infrastructure, install kubeconfig, create platform resources and sync the secret
	$(MAKE) bootstrap-state STATE_BUCKET=$(STATE_BUCKET) STATE_PROJECT_ID=$(STATE_PROJECT_ID) STATE_REGION=$(STATE_REGION)
	$(MAKE) infra-apply AUTO_APPROVE=$(AUTO_APPROVE)
	$(MAKE) kubeconfig
	$(MAKE) platform-apply AUTO_APPROVE=$(AUTO_APPROVE)
	$(MAKE) sync-secret

plan: ## Review both Terraform plans in deployment order
	$(MAKE) infra-plan
	$(MAKE) platform-plan

fmt: ## Format Terraform files
	$(TF) fmt -recursive

validate: ## Initialize providers without a backend and validate both Terraform roots
	@set -eu; for dir in $(INFRA_DIR) $(K8S_DIR); do \
		$(TF) -chdir=$$dir init -backend=false -input=false; \
		$(TF) -chdir=$$dir validate; \
	done

shell-syntax: ## Check shell script syntax with Bash
	@set -eu; for script in $(SCRIPTS_DIR)/*.sh; do bash -n "$$script"; done

status: ## Show cluster nodes, PVCs, Jobs and pods
	kubectl get nodes -o wide
	kubectl get pvc -n $(NAMESPACE)
	kubectl get jobs,pods -n $(NAMESPACE) -o wide

outputs: ## Show infrastructure outputs
	$(TF) -chdir=$(INFRA_DIR) output

bootstrap-reference: ## Download and prepare GRCh38 reference data on the reference PVC
	bash $(SCRIPTS_DIR)/bootstrap-reference.sh

prepare-demo: ## Download and upload the human validation dataset (requires RUN_ID)
	@test -n "$(RUN_ID)" || { echo 'Set RUN_ID, e.g. make prepare-demo RUN_ID=validation-20260925'; exit 2; }
	bash $(SCRIPTS_DIR)/prepare-demo.sh "$(RUN_ID)"

run-pipeline: ## Run nf-core/rnaseq (requires RUN_ID; set RESUME=1 to resume)
	@test -n "$(RUN_ID)" || { echo 'Set RUN_ID, e.g. make run-pipeline RUN_ID=validation-20260925'; exit 2; }
	@if [ "$(RESUME)" = 1 ]; then \
		bash $(SCRIPTS_DIR)/run-pipeline.sh "$(RUN_ID)" --resume -- --save_align_intermeds true $(NF_ARGS); \
	else \
		bash $(SCRIPTS_DIR)/run-pipeline.sh "$(RUN_ID)" -- --save_align_intermeds true $(NF_ARGS); \
	fi

validate-run: ## Validate pipeline outputs for RUN_ID
	@test -n "$(RUN_ID)" || { echo 'Set RUN_ID, e.g. make validate-run RUN_ID=validation-20260925'; exit 2; }
	bash $(SCRIPTS_DIR)/validate-run.sh "$(RUN_ID)"

smoke-test: ## Prepare, run and validate the small human genomic validation dataset
	@test -n "$(RUN_ID)" || { echo 'Set RUN_ID, e.g. make smoke-test RUN_ID=validation-20260925'; exit 2; }
	@if [ "$(RESUME)" = 1 ]; then \
		bash $(SCRIPTS_DIR)/smoke-test.sh "$(RUN_ID)" --resume; \
	else \
		bash $(SCRIPTS_DIR)/smoke-test.sh "$(RUN_ID)"; \
	fi

deploy-and-validate: ## Deploy everything, prepare GRCh38, and run an end-to-end human validation
	@test -n "$(RUN_ID)" || { echo 'Set RUN_ID, e.g. make deploy-and-validate RUN_ID=validation-20260925'; exit 2; }
	$(MAKE) cluster STATE_BUCKET="$(STATE_BUCKET)" STATE_PROJECT_ID="$(STATE_PROJECT_ID)" STATE_REGION="$(STATE_REGION)" AUTO_APPROVE=$(AUTO_APPROVE)
	$(MAKE) smoke-test RUN_ID=$(RUN_ID)

destroy: ## Destroy platform then infrastructure (interactive; back up SFS data first)
	$(TF) -chdir=$(K8S_DIR) destroy -input=false -var-file=terraform.tfvars $(KUBECONFIG_ARG)
	$(TF) -chdir=$(INFRA_DIR) destroy -input=false -var-file=terraform.tfvars
