# Needs Agentica 0.34.1 or later on PATH (or AGENTICA=/path/to/agentica).
AGENTICA ?= agentica

# The tests of tests/bindings_test.agc and tests/fetch_test.agc; a run that tests nothing fails.
BINDINGS_TESTS = 15
FETCH_TESTS = 2

.PHONY: install fetch check fmt-check check-bindings test-bindings test-fetch test

install:
	$(AGENTICA) install

# The llama.cpp libraries, their headers and the model: nothing here is committed.
fetch:
	$(AGENTICA) scripts/fetch.agc all

# The manifest names the llama.cpp libraries, so `agentica scripts/fetch.agc llama` runs first.
check:
	$(AGENTICA) check

fmt-check:
	$(AGENTICA) fmt --check server.agc smoke.agc src scripts tests

# The structs and functions of llama.agc against the llama.cpp headers, and their sizes against the C compiler's.
# Needs `agentica scripts/fetch.agc headers` and `llama`.
check-bindings:
	$(AGENTICA) scripts/check_bindings.agc

# The mutations of llama.agc that check-bindings must refuse. Needs what check-bindings needs.
test-bindings:
	@$(AGENTICA) test tests/bindings_test.agc > bindings-test.log; status=$$?; cat bindings-test.log; \
	test $$status -eq 0 && grep -q "^$(BINDINGS_TESTS) passed, 0 failed, 0 skipped, 0 not executed, 0 file errors" bindings-test.log

# scripts/fetch.agc against a local server that redirects and serves ranges. Needs nothing fetched.
test-fetch:
	@$(AGENTICA) test tests/fetch_test.agc > fetch-test.log; status=$$?; cat fetch-test.log; \
	test $$status -eq 0 && grep -q "^$(FETCH_TESTS) passed, 0 failed, 0 skipped, 0 not executed, 0 file errors" fetch-test.log

# Needs `agentica scripts/fetch.agc all`.
test: test-bindings test-fetch
	AGENTICA=$(AGENTICA) python3 -m unittest tests.test_cli tests.test_api
