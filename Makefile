# Symaira Cockpit — aggregation Makefile
# Builds and tests the nested SPM packages (tuning and history).

PACKAGES := tuning history

# Resolve a full Xcode toolchain: CommandLineTools alone fails on actool.
# If xcode-select points at CommandLineTools, fall back to an installed Xcode.
XCODE_SELECT := $(shell xcode-select -p 2>/dev/null)
ifeq ($(findstring CommandLineTools,$(XCODE_SELECT)),CommandLineTools)
TOOLCHAIN := $(firstword $(foreach d,/Applications/Xcode-beta.app/Contents/Developer /Applications/Xcode.app/Contents/Developer,$(if $(wildcard $d),$d)))
else
TOOLCHAIN := $(XCODE_SELECT)
endif
export DEVELOPER_DIR = $(TOOLCHAIN)

# Locally the build guard (Dev/Verwaltung/ABLAGEREGELN.md) requires the launcher.
DEV_EXTERNAL := $(HOME)/.local/bin/dev-external
CARGO ?= $(if $(wildcard $(DEV_EXTERNAL)),$(DEV_EXTERNAL) cargo,cargo)

.PHONY: build test build-%% test-%% build-app smoke-app run-app clean rust-build rust-test oracle

## build: Build all packages
build:
	@rc=0; for p in $(PACKAGES); do \
		[ -d "$$p" ] || continue; \
		echo "==> build $$p"; \
		( cd $$p && swift build ) || rc=1; \
	done; exit $$rc

## test: Test all packages
test:
	@rc=0; for p in $(PACKAGES); do \
		[ -d "$$p" ] || continue; \
		echo "==> test $$p"; \
		( cd $$p && swift test ) || rc=1; \
	done; exit $$rc

## rust-build: Build the Rust workspace (CARGO="dev-external cargo" is picked up when installed)
rust-build:
	$(CARGO) build --workspace --locked

## rust-test: Test the Rust workspace
rust-test:
	$(CARGO) test --workspace --locked

## oracle: Compare a binary with the frozen v0.12 oracle: make oracle BIN=<path to symcockpit>
oracle:
	@test -n "$(BIN)" || { echo "usage: make oracle BIN=<path to symcockpit>" >&2; exit 2; }
	SYMCOCKPIT_ORACLE_BIN="$(abspath $(BIN))" $(CARGO) test --locked -p symcockpit-oracle --test live -- --ignored --nocapture

## build-app: Assemble the GUI bundle (build/app/Symaira Cockpit.app)
build-app:
	./scripts/build-app.sh

## smoke-app: Structural check on the assembled GUI bundle
smoke-app: build-app
	./scripts/smoke-app.sh

## run-app: Build and launch the GUI
run-app: build-app
	open "build/app/Symaira Cockpit.app"

## build-<pkg>: Build a single package (e.g. make build-tuning)
build-%:
	cd $* && swift build

## test-<pkg>: Test a single package (e.g. make test-tuning)
test-%:
	cd $* && swift test

## clean: Remove build artifacts from all packages and the GUI bundle
clean:
	rm -rf build .build
	@for p in $(PACKAGES); do \
		if [ -d "$$p" ]; then \
			cd $$p && rm -rf .build && cd ..; \
		fi; \
	done
