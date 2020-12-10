## Define sources for rendering and templating
BUILD_TIMESTAMP := $(shell date -u +'%Y-%m-%dT%H:%M:%SZ')
BUILD_URL ?= localbuild://${USER}@$(shell uname -n | sed "s/'//g")
DOCKER_IMAGE ?= 'quay.io/razee/remoteresources3ansiblevault'
DOCKER_PULL_OPTS ?= ''
GIT_BRANCH ?= $(shell git branch --show-current)
GIT_URL ?= $(shell git remote get-url origin)
GIT_REF ?= $(or $(TRAVIS_COMMIT), $(shell git rev-parse HEAD))
PACKAGE_VERSION := $(shell awk '/version/ {gsub(/[",]/,""); print $$2}' package.json)
SOURCE_DIR ?= kubernetes
TMP_DIR ?= tmp
URL ?= 'https://razee.io'
VERSION ?= $(or $(TRAVIS_TAG), $(PACKAGE_VERSION))

# Define commands via docker
DOCKER = docker

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
	@echo Publishing environment check complete

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
	$(KUBEVAL_COMMAND) -d /data/$(OUTPUT_DIR) --ignored-filename-patterns='mtp-*'

.PHONY:lint-k8s-local
lint-k8s-local: $(LOCAL_OUTPUTS)   ## Run kubeval linting against the mustache generated resources
	$(KUBEVAL_COMMAND) -d /data/$(RENDERED_DIR) --ignore-missing-schemas

.PHONY:lint-yaml
lint-yaml: $(OUTPUTS)     ## Run yaml linting against most of the k8s resources
	$(YAMLLINT_COMMAND) /data/$(OUTPUT_DIR)

.PHONY:lint-yaml-local
lint-yaml-local: $(LOCAL_OUTPUTS)     ## Run yaml linting against the mustache generated resources
	$(YAMLLINT_COMMAND) /data/$(RENDERED_DIR)

.PHONY:lint-docker
lint-docker: ## Lint the Dockerfile for issues
	$(HADOLINT_COMMAND) Dockerfile

.PHONY:lint-npm
lint-npm:
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
publish-build-image: ## Publish SemVer compliant releases to our internal docker registry
	$(DOCKER) push $(DOCKER_IMAGE):$(TRAVIS_COMMIT)

.PHONY:publish-image
publish-image: ## Publish SemVer compliant releases to our internal docker registry
	@for version in $(TARGET_VERSIONS); do \
		$(DOCKER) tag $(DOCKER_IMAGE):$(VCS_REF) $(DOCKER_IMAGE):$${version}; \
		$(DOCKER) push $(DOCKER_IMAGE):$${version}; \
	done

.PHONY:publish-release
publish-release: ## Publish SemVer compliant release to GitHub Releases


.PHONY:publish
publish: publish-image   ## Runs all publish rules
