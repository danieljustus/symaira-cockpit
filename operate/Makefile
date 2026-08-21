BINARY := symoperate

.PHONY: build release test lint coverage run doctor serve clean

build:
	swift build

release:
	swift build -c release

test:
	swift test

coverage:
	swift test --enable-code-coverage
	@rm -f .build/coverage.profdata .build/coverage.json
	@find .build -type d -name codecov -exec find {} -name '*.profraw' -print0 \; 2>/dev/null | xargs -0 xcrun llvm-profdata merge -sparse -o .build/coverage.profdata 2>/dev/null; \
	if [ -f .build/coverage.profdata ]; then \
	  BINARIES="$$(find .build \( -path '*/SymOperateCore.build/*.o' -o -name 'SymOperateCore.o' \) -type f)"; \
	  if [ -n "$$BINARIES" ]; then \
	    xcrun llvm-cov report \
	      $$BINARIES \
	      --instr-profile=.build/coverage.profdata \
	      --use-color=false \
	      Sources/SymOperateCore/ > .build/coverage-report.txt; \
	    TOTAL=$$(tail -1 .build/coverage-report.txt | awk '{print $$10}' | sed 's/%//'); \
	    printf '{"coverage": %.1f, "generated_at": "%s"}\n' "$$TOTAL" "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" > .build/coverage.json; \
	    echo "Coverage: $$TOTAL%"; \
	  else \
	    echo "ERROR: SymOperateCore.o not found" >&2; \
	  fi; \
	else \
	  echo "ERROR: Failed to generate coverage.profdata" >&2; \
	  echo "Codecov dirs:" >&2; \
	  find .build -type d -name codecov >&2; \
	  echo "Profraw files:" >&2; \
	  find .build -name '*.profraw' >&2; \
	fi

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
