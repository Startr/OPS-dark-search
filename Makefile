# 1. help (default target — must come first)
help:
	@echo "================================================"
	@echo "       $(OWNER)/$(PROJECT_NAME) by Startr.Cloud"
	@echo "================================================"
	@echo "This is the default make command."
	@echo "This command lists available make commands."
	@echo ""
	@echo "Usage example:"
	@echo "    make deploy"
	@echo ""
	@echo "Available make commands:"
	@echo ""
	@LC_ALL=C $(MAKE) -pRrq -f $(firstword $(MAKEFILE_LIST)) : 2>/dev/null | \
		awk -v RS= -F: '/(^|\n)# Files(\n|$$)/,/(^|\n)# Finished Make data base/ { \
		if ($$1 !~ "^[#.]") {print $$1}}' | \
		sort | \
		grep -E -v -e '^[^[:alnum:]]' -e '^$$@$$'
	@echo ""

# 2. Dynamic variable extraction (mirrors startr.sh)
PROJECTPATH := $(shell git rev-parse --show-toplevel 2>/dev/null || pwd)
PROJECT     := $(shell echo $$(basename $(PROJECTPATH)) | tr '[:upper:]' '[:lower:]')
# Use symbolic-ref (clean failure on empty repos) → short SHA (detached HEAD) → develop fallback.
FULL_BRANCH := $(shell git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo "develop")
BRANCH      := $(shell echo $(FULL_BRANCH) | sed 's/.*\///' | tr '[:upper:]' '[:lower:]')
TAG         := $(shell git describe --always --tag 2>/dev/null || echo "v0.0.0")

# Owner and project name extracted from git remote URL
REMOTE_URL   := $(shell git config --get remote.origin.url 2>/dev/null || echo "unknown/unknown")
OWNER        := $(shell echo $(REMOTE_URL) | sed -E 's|.*[:/]([^/]+)/[^/]+(.git)?$$|\1|')
PROJECT_NAME := $(shell echo $(REMOTE_URL) | sed -E 's|.*[:/][^/]+/([^/]+)(.git)?$$|\1|' | sed 's/\.git$$//')

# Container name (used by Docker block)
CONTAINER := $(PROJECT)-$(BRANCH)

# 3. Load environment overrides from .env if present
-include .env

# 4. Project-specific custom targets ------------------------------------------

# SearXNG base-image version policy: pin the exact tag in the Dockerfile, surface
# upstream drift on every deploy, never auto-bump.
PINNED    = $(shell sed -n 's|^FROM searxng/searxng:||p' Dockerfile)
UPSTREAM  = $(shell curl -s 'https://hub.docker.com/v2/repositories/searxng/searxng/tags?page_size=25' \
              | jq -r '.results[].name' | grep -E '^20[0-9.]+-' | sort -V | tail -1)

check-upstream:
	@echo "pinned: $(PINNED)  upstream: $(UPSTREAM)"
	@[ "$(PINNED)" = "$(UPSTREAM)" ] || echo "⚠ newer searxng available — run 'make bump', review, commit, redeploy"

bump:
	sed -i '' 's|^FROM searxng/searxng:.*|FROM searxng/searxng:$(UPSTREAM)|' Dockerfile
	@echo "Dockerfile now pins $(UPSTREAM) — review, commit, deploy"

# Poka-yoke: every egress/hosts/*.env PORT must have a matching socks5h proxy line
# in searxng/settings.yml, and vice versa. A registered host no engine uses, or a
# proxy line with no host behind it, fails the deploy.
check-proxies:
	@fail=0; \
	for f in egress/hosts/*.env; do \
		port=$$(sed -n 's/^PORT=//p' "$$f"); \
		grep -q "socks5h://172.18.0.1:$$port" searxng/settings.yml \
			|| { echo "✗ $$f (PORT=$$port) has no proxy line in searxng/settings.yml"; fail=1; }; \
	done; \
	for port in $$(grep -o 'socks5h://172\.18\.0\.1:[0-9]*' searxng/settings.yml | sed 's/.*://' | sort -u); do \
		grep -qs "^PORT=$$port$$" egress/hosts/*.env \
			|| { echo "✗ settings.yml proxies port $$port but no egress/hosts/*.env declares it"; fail=1; }; \
	done; \
	[ $$fail = 0 ] && echo "OK: hosts and proxy lines match one-to-one" || exit 1

# 5. CapRover deploy -----------------------------------------------------------
HAS_SUBMODULE := $(shell [ -f .gitmodules ] && echo 1)
HAS_CAPROVER  := $(shell which caprover 2>/dev/null && echo 1)

deploy: check-upstream check-proxies
	@if [ "$(HAS_CAPROVER)" = "" ]; then \
		echo "CapRover CLI not installed. Run: npm install -g caprover"; exit 1; \
	fi
	@if [ "$(HAS_SUBMODULE)" = "1" ]; then \
		echo "Submodules detected — deploying via tar"; \
		git ls-files --recurse-submodules | tar -czf deploy.tar -T -; \
		npx caprover deploy -t ./deploy.tar; \
		rm ./deploy.tar; \
	else \
		npx caprover deploy; \
	fi

# 6. Docker lifecycle ----------------------------------------------------------
it_stop:
	-docker stop $(CONTAINER)
	-docker rm $(CONTAINER)

it_clean:
	docker image prune -f
	docker builder prune -f

it_gone: it_stop
	-docker rmi $(CONTAINER):$(BRANCH)

# 7. show_vars + verify (debug / one-shot self-check) --------------------------
show_vars:
	@echo "=== Dynamic Variables ==="
	@echo "PROJECTPATH=$(PROJECTPATH)"
	@echo "PROJECT=$(PROJECT)"
	@echo "OWNER=$(OWNER)"
	@echo "PROJECT_NAME=$(PROJECT_NAME)"
	@echo "FULL_BRANCH=$(FULL_BRANCH)"
	@echo "BRANCH=$(BRANCH)"
	@echo "TAG=$(TAG)"
	@echo "CONTAINER=$(CONTAINER)"
	@echo "REMOTE_URL=$(REMOTE_URL)"
	@echo ""

# One-shot scaffold self-check. Bundles every read-only verification into a
# single make invocation so post-scaffold testing isn't N separate processes.
verify: show_vars require_gitflow_next check-proxies
	@echo "=== Targets defined in this Makefile ==="
	@LC_ALL=C $(MAKE) -pRrq -f $(firstword $(MAKEFILE_LIST)) : 2>/dev/null | \
		awk -v RS= -F: '/(^|\n)# Files(\n|$$)/,/(^|\n)# Finished Make data base/ { \
		if ($$1 !~ "^[#.]") {print "  " $$1}}' | \
		sort -u | \
		grep -E -v -e '^  [^[:alnum:]]'
	@echo ""
	@echo "OK: Makefile scaffold verified."

# 8. Git-flow-next release/hotfix flow -----------------------------------------
require_gitflow_next:
	@if ! git flow version 2>/dev/null | grep -q 'git-flow-next'; then \
		echo "Error: git-flow-next required (Go rewrite). Install: brew install git-flow-next"; \
		exit 1; \
	fi

minor_release: require_gitflow_next
	# Start a minor release with incremented minor version
	git flow release start $$(git tag --sort=-v:refname | sed 's/^v//' | head -n 1 | awk -F'.' '{print $$1"."$$2+1".0"}') && echo "or use 'make release_finish' to finish the release"

patch_release: require_gitflow_next
	# Start a patch release with incremented patch version
	git flow release start $$(git tag --sort=-v:refname | sed 's/^v//' | head -n 1 | awk -F'.' '{print $$1"."$$2"."$$3+1}') && echo "or use 'make release_finish' to finish the release"

major_release: require_gitflow_next
	# Start a major release with incremented major version
	git flow release start $$(git tag --sort=-v:refname | sed 's/^v//' | head -n 1 | awk -F'.' '{print $$1+1".0.0"}') && echo "or use 'make release_finish' to finish the release"

hotfix: require_gitflow_next
	# Start a hotfix with incremented n.n.n.n version (incrementing the fourth number)
	git flow hotfix start $$(git tag --sort=-v:refname | sed 's/^v//' | head -n 1 | awk -F'.' '{print $$1"."$$2"."$$3"."$$4+1}') && echo "or use 'make hotfix_finish' to finish the hotfix"

release_finish: require_gitflow_next
	git flow release finish && git push origin develop && git push origin master && git push --tags && git checkout develop

hotfix_finish: require_gitflow_next
	git flow hotfix finish && git push origin develop && git push origin master && git push --tags && git checkout master

# 9. things_clean ---------------------------------------------------------------
things_clean:
	git clean --exclude='!.env*' -Xdf

# 10. .PHONY --------------------------------------------------------------------
.PHONY: help show_vars verify require_gitflow_next \
	minor_release patch_release major_release hotfix \
	release_finish hotfix_finish things_clean \
	it_stop it_clean it_gone \
	deploy check-upstream bump check-proxies
