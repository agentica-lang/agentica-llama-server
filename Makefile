# Needs Agentica 0.34.1 or later on PATH (or AGENTICA=/path/to/agentica).
AGENTICA ?= agentica

# The number of tests each file of tests/ has: a run that tests fewer, or nothing, fails.
BINDINGS_TESTS = 19
FETCH_TESTS = 10
CLI_TESTS = 5
API_TESTS = 8

.PHONY: install fetch check fmt-check check-bindings test-bindings test-fetch test-cli test-api test

install:
	$(AGENTICA) install

# The llama.cpp libraries, their headers and the model: nothing here is committed.
fetch:
	$(AGENTICA) scripts/fetch.agc all

# The manifest names the llama.cpp libraries, so `agentica scripts/fetch.agc llama` runs first.
check:
	$(AGENTICA) check

fmt-check:
	$(AGENTICA) fmt --check server.agc smoke.agc src scripts tests bench

# The structs and functions of llama.agc against the llama.cpp headers, and their sizes against the C compiler's.
# Needs `agentica scripts/fetch.agc headers` and `llama`.
check-bindings:
	$(AGENTICA) scripts/check_bindings.agc

# $(call agc_tests,NAME,COUNT): `agentica test tests/NAME_test.agc`, which must pass exactly COUNT tests.
define agc_tests
@$(AGENTICA) test tests/$(1)_test.agc > tests/$(1).log; status=$$?; cat tests/$(1).log; \
test $$status -eq 0 && grep -q "^$(2) passed, 0 failed, 0 skipped, 0 not executed, 0 file errors" tests/$(1).log
endef

# The mutations of llama.agc that check-bindings must refuse. Needs what check-bindings needs.
test-bindings:
	$(call agc_tests,bindings,$(BINDINGS_TESTS))

# scripts/fetch.agc against a local server that redirects and serves ranges. Needs nothing fetched.
test-fetch:
	$(call agc_tests,fetch,$(FETCH_TESTS))

# The command line of server.agc. Needs `agentica scripts/fetch.agc llama`.
test-cli:
	$(call agc_tests,cli,$(CLI_TESTS))

# The server on a free port with the small model. Needs `agentica scripts/fetch.agc all`.
test-api:
	$(call agc_tests,api,$(API_TESTS))

test: test-bindings test-fetch test-cli test-api
