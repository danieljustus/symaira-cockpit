BINARY := symtune

.PHONY: build build-app smoke-app release test coverage lint run doctor serve clean

build:
	swift build

build-app:
	./scripts/build-app.sh

smoke-app: build-app
	./scripts/smoke-app.sh build/app/SymairaTune.app

release:
	swift build -c release

test:
	swift test

# Coverage for the library targets. The symtune executable is not instrumented
# (its tests spawn the binary), so its lines are absent from the report — see
# scripts/coverage.sh for the full scope note.
coverage:
	./scripts/coverage.sh

lint:
	@command -v swiftlint >/dev/null 2>&1 && swiftlint --quiet || echo "swiftlint not installed; skipping"

run: build
	swift run -q $(BINARY) doctor

doctor: build
	swift run -q $(BINARY) doctor

serve: build
	swift run -q $(BINARY) serve

clean:
	swift package clean
	rm -rf .build
