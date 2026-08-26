# Symaira Cockpit — aggregation Makefile
# Builds and tests all nested SPM packages (tune, operate, scope).

PACKAGES := tune operate scope

# Resolve a full Xcode toolchain: CommandLineTools alone fails on actool.
# If xcode-select points at CommandLineTools, fall back to an installed Xcode.
XCODE_SELECT := $(shell xcode-select -p 2>/dev/null)
ifeq ($(findstring CommandLineTools,$(XCODE_SELECT)),CommandLineTools)
TOOLCHAIN := $(firstword $(foreach d,/Applications/Xcode-beta.app/Contents/Developer /Applications/Xcode.app/Contents/Developer,$(if $(wildcard $d),$d)))
else
TOOLCHAIN := $(XCODE_SELECT)
endif
export DEVELOPER_DIR = $(TOOLCHAIN)

.PHONY: build test build-%% test-%% build-app smoke-app run-app clean

## build: Build all packages
build:
	@for p in $(PACKAGES); do \
		if [ -d "$$p" ]; then \
			echo "==> build $$p"; \
			cd $$p && swift build && cd ..; \
		fi; \
	done

## test: Test all packages
test:
	@for p in $(PACKAGES); do \
		if [ -d "$$p" ]; then \
			echo "==> test $$p"; \
			cd $$p && swift test && cd ..; \
		fi; \
	done

## build-app: Assemble the GUI bundle (build/app/Symaira Cockpit.app)
build-app:
	./scripts/build-app.sh

## smoke-app: Structural check on the assembled GUI bundle
smoke-app: build-app
	./scripts/smoke-app.sh

## run-app: Build and launch the GUI
run-app: build-app
	open "build/app/Symaira Cockpit.app"

## build-<pkg>: Build a single package (e.g. make build-tune)
build-%:
	cd $* && swift build

## test-<pkg>: Test a single package (e.g. make test-operate)
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
