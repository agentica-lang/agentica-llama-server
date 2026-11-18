# Needs Agentica 0.34.1 or later on PATH (or AGENTICA=/path/to/agentica).
AGENTICA ?= agentica

# The tests of tests/bindings_test.agc; a run that tests nothing fails.
BINDINGS_TESTS = 15

.PHONY: install check fmt-check check-bindings test-bindings test

install:
	$(AGENTICA) install

# The manifest names the llama.cpp libraries, so scripts/fetch-llama.sh runs first.
check:
	$(AGENTICA) check

fmt-check:
	$(AGENTICA) fmt --check server.agc smoke.agc src scripts tests

# The structs and functions of llama.agc against the llama.cpp headers, and their sizes against the C compiler's.
# Needs scripts/fetch-headers.sh and scripts/fetch-llama.sh.
check-bindings:
	$(AGENTICA) scripts/check_bindings.agc

# The mutations of llama.agc that check-bindings must refuse. Needs what check-bindings needs.
test-bindings:
	@$(AGENTICA) test tests/bindings_test.agc > bindings-test.log; status=$$?; cat bindings-test.log; \
	test $$status -eq 0 && grep -q "^$(BINDINGS_TESTS) passed, 0 failed, 0 skipped, 0 not executed, 0 file errors" bindings-test.log

# Needs scripts/fetch-llama.sh, scripts/fetch-headers.sh and scripts/fetch-model.sh.
test: test-bindings
	AGENTICA=$(AGENTICA) python3 -m unittest tests.test_cli tests.test_api
