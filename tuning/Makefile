# The CLI and MCP server are the Rust `symcockpit` binary (make rust-build at the
# repo root); this package holds the Swift GUI libraries only.
.PHONY: build build-app smoke-app release test coverage lint clean

build:
	swift build

build-app:
	./scripts/build-app.sh

smoke-app: build-app
	./scripts/smoke-app.sh "build/app/Symaira Cockpit Menu Bar.app"

release:
	swift build -c release

test:
	swift test

# Coverage for the library targets. The UI and app entry points are not linked
# into the package-local test bundles, so their lines are absent from the
# report — see scripts/coverage.sh for the full scope note.
coverage:
	./scripts/coverage.sh

lint:
	@command -v swiftlint >/dev/null 2>&1 && swiftlint --quiet || echo "swiftlint not installed; skipping"

clean:
	swift package clean
	rm -rf .build
