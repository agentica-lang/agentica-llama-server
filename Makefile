# Needs Agentica 0.34.1 or later on PATH (or AGENTICA=/path/to/agentica).
AGENTICA ?= agentica

.PHONY: install check fmt-check check-bindings test

install:
	$(AGENTICA) install

# The manifest names the llama.cpp libraries, so scripts/fetch-llama.sh runs first.
check:
	$(AGENTICA) check

fmt-check:
	$(AGENTICA) fmt --check server.agc smoke.agc src scripts

# The structs and functions of llama.agc against the llama.cpp headers, and their sizes against the C compiler's.
# Needs scripts/fetch-headers.sh and scripts/fetch-llama.sh.
check-bindings:
	$(AGENTICA) scripts/check_bindings.agc

# Needs scripts/fetch-llama.sh, scripts/fetch-headers.sh and scripts/fetch-model.sh.
test:
	AGENTICA=$(AGENTICA) python3 -m unittest tests.test_cli tests.test_api tests.test_bindings
