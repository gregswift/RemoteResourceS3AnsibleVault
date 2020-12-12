## Define sources for rendering and templating
BUILD_TIMESTAMP := $(shell date -u +'%Y-%m-%dT%H:%M:%SZ')
BUILD_URL ?= localbuild://${USER}@$(shell uname -n | sed "s/'//g")
CI_TAG = $(TRAVIS_TAG)
DOCKER_IMAGE ?= 'quay.io/razee/remoteresources3ansiblevault'
DOCKER_PULL_OPTS ?= ''
GIT_BRANCH ?= $(shell git branch --show-current)
GIT_URL ?= $(shell git remote get-url origin)
GIT_REF ?= $(or $(TRAVIS_COMMIT), $(shell git rev-parse HEAD))
GIT_SHORTREF ?= $(shell git rev-parse --short HEAD)
GIT_TAG ?= $(shell git describe --tags 2>/dev/null)
HADOLINT_IMAGE_REPO ?= hadolint/hadolint
HADOLINT_IMAGE_TAG ?= v1.18.0-debian
HADOLINT_IMAGE ?= $(HADOLINT_IMAGE_REPO):$(HADOLINT_IMAGE_TAG)
HADOLINT_IMAGE := $(HADOLINT_IMAGE)
IS_RELEASE ?= $(if $(CI_TAG), true)
PACKAGE_VERSION := $(shell awk '/version/ {gsub(/[",]/,""); print $$2}' package.json)
SOURCE_DIR ?= kubernetes
TMP_DIR ?= tmp
URL ?= 'https://razee.io'
VERSION ?= $(or $(GIT_TAG), $(PACKAGE_VERSION))

# Check if this is via CI
CI_MODE := $(if $(TRAVIS_COMMIT), "--ci")

# Define commands
DOCKER = docker
DOCKER_RUN := $(DOCKER) run --rm -i
RELEASEIT = npx release-it
HADOLINT := $(DOCKER_RUN) -v ${PWD}/.hadolint.yml:/.hadolint.yaml $(HADOLINT_IMAGE)
KUBEVAL := $(DOCKER_RUN) -v $(PWD):/data:Z garethr/kubeval --ignore-missing-schemas
YAMLLINT := $(DOCKER_RUN) -v $(PWD):/data:Z cytopia/yamllint:latest

# Get list of files to render
SOURCE_FILES := $(wildcard $(SOURCE_DIR)/*.yaml)
RENDERED_FILES := $(patsubst $(SOURCE_DIR)/%.yaml,$(TMP_DIR)/%.yaml,$(SOURCE_FILES))

# Breakout VERSION'ing for SEMVER, Image Patching, and Publishing
MAJOR_VERSION := $(shell echo $(VERSION) | cut -f1 -d'.')
MINOR := $(shell echo $(VERSION) | cut -f1-2 -d'.')
MINOR_VERSION := $(MAJOR_VERSION).$(MINOR_VERSION)
PATCH := $(shell echo $(VERSION) | cut -f1 -d'-')
PATCH_VERSION := $(MAJOR_VERSION).$(MINOR_VERSION).$(PATCH_VERSION)
# This release version is for patching of the underlying Image
RELEASE_VERSION := $(MAJOR_VERSION).$(MINOR_VERSION).$(PATCH_VERSION)-$(shell date -u +'%Y%m%d')
TARGET_VERSIONS := $(VERSION) $(MAJOR_VERSION) $(MINOR_VERSION) $(PATCH_VERSION) $(RELEASE_VERSION) latest

# Exports the variables for shell use
export

# This helper function makes debuging much easier.
.PHONY:debug-%
debug-%:              ## Debug a variable by calling `make debug-VARIABLE`
	@echo $(*) = $($(*))

.PHONY:help
.SILENT:help
help:                 ## Show this help, includes list of all actions.
	@awk 'BEGIN {FS = ":.*?## "}; /^.+: .*?## / && !/awk/ {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}' ${MAKEFILE_LIST}

.PHONY:setup
setup:       ## Install any dev dependencies
	npm ci

.PHONY:.check-env
.check-env: .check-env-publish

.PHONY:.check-env-publish
.check-env-publish:
	@if [ "${AWS_PROFILE}" == "" ]; then \
		if [ "${AWS_SECRET_ACCESS_KEY}" == "" ] || [ "${AWS_ACCESS_KEY_ID}" == "" ]; then \
			echo "ERROR: AWS_PROFILE _or_ AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must be profiled"; \
			exit 1; \
		fi; \
	fi
	@test $${GITHUB_TOKEN:ERROR Undefined GITHUB_TOKEN required to publish releases}
	@echo Publishing environment check complete

.PHONY:.check-env-release
.check-env-release: .check-env-publish
	@test $${IS_RELEASE?ERROR: Undefined IS_RELEASE - Not Identified as an official release to cut}
	@echo Release environment check complete

.PHONY:clean
clean:          ## Cleanup the local checkout
	-rm -rf *.backup

.PHONY:clean-all clean-docker
clean-all: clean      ## Full cleanup of all artifacts
	-git clean -Xdf

$(TMP_DIR):
	mkdir -p $(@)

$(RENDERED_FILES): $(SOURCE_FILES) | $(TMP_DIR)
	envsubst < $(<) > $(@)

.PHONY:render
render: $(RENDERED_FILES)

.PHONY:lint-k8s
lint-k8s: $(OUTPUTS)   ## Run kubeval linting against most of the k8s resources
	$(KUBEVAL) -d /data/$(OUTPUT_DIR) --ignored-filename-patterns='mtp-*'

.PHONY:lint-k8s-local
lint-k8s-local: $(LOCAL_OUTPUTS)   ## Run kubeval linting against the mustache generated resources
	$(KUBEVAL) -d /data/$(RENDERED_DIR) --ignore-missing-schemas

.PHONY:lint-yaml
lint-yaml: $(OUTPUTS)     ## Run yaml linting against most of the k8s resources
	$(YAMLLINT) /data/$(OUTPUT_DIR)

.PHONY:lint-yaml-local
lint-yaml-local: $(LOCAL_OUTPUTS)     ## Run yaml linting against the mustache generated resources
	$(YAMLLINT) /data/$(RENDERED_DIR)

.PHONY:lint-docker
lint-docker: ## Lint the Dockerfile for issues
	$(HADOLINT) < Dockerfile

.PHONY:lint-npm
lint-npm: setup
	npm run lint

.PHONY:lint
lint: lint-npm lint-docker render-local lint-k8s lint-k8s-local lint-yaml lint-yaml-local   ## Run all linting rules

.PHONY:audit
audit:      ## Run NPM audit
	npm audit

.PHONY:audit
fix-audit:      ## Run NPM audit, and install compatible updates
	npm audit fix

.PHONY:test
test:      ## Run all test rules
	npm test

.PHONY:clean-docker
clean-docker: ## Cleans the intermediate and final cdn images left over from the build-image target
	@# Clean any agent images, left over from the multi-stage build
	if [[ ! -z "$(shell docker images -q $(CLEAN_FILTERS))" ]]; then docker images -q $(CLEAN_FILTERS) | xargs docker rmi -f; fi

.PHONY:build-image
build-image: ## Build a docker image as specified in the Dockerfile
	$(DOCKER) build . -t $(DOCKER_IMAGE):$(TRAVIS_COMMIT) -f Dockerfile \
		$(DOCKER_PULL_OPTS) --no-cache=true --rm \
		--build-arg BUILD_TIMESTAMP=$(BUILD_TIMESTAMP) \
		--build-arg URL=$(URL) \
		--build-arg VERSION=$(VERSION) \
		--build-arg VCS_REF=$(GIT_REF) \
		--build-arg VCS_URL=$(GIT_URL)

.PHONY:publish-build-image
publish-build-image: .check-env-publish ## Publish SemVer compliant releases to our internal docker registry
	$(DOCKER) push $(DOCKER_IMAGE):$(GIT_SHORTREF)

.PHONY:publish-image
publish-image: .check-env-release ## Publish SemVer compliant releases to our internal docker registry
	@for version in $(TARGET_VERSIONS); do \
		$(DOCKER) tag $(DOCKER_IMAGE):$(GIT_SHORTREF) $(DOCKER_IMAGE):$${version}; \
		$(DOCKER) push $(DOCKER_IMAGE):$${version}; \
	done

.PHONY:publish-release
publish-release: .check-env-release ## Publish SemVer compliant release to GitHub Releases
	$(RELEASEIT) $(CI_MODE)

.PHONY:publish
publish: publish-build-image publish-image publish-release  ## Runs all publish rules
