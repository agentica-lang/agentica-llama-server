# Needs Agentica 0.34.1 or later on PATH (or AGENTICA=/path/to/agentica).
AGENTICA ?= agentica

.PHONY: install fetch check fmt-check check-bindings test

install:
	$(AGENTICA) install

# The llama.cpp libraries, their headers and the model: nothing here is committed.
fetch:
	$(AGENTICA) scripts/fetch.agc all

# The manifest names the llama.cpp libraries, so `agentica scripts/fetch.agc llama` runs first.
check:
	$(AGENTICA) check

fmt-check:
	$(AGENTICA) fmt --check server.agc smoke.agc src scripts

# The structs and functions of llama.agc against the llama.cpp headers, and their sizes against the C compiler's.
# Needs `agentica scripts/fetch.agc headers` and `llama`.
check-bindings:
	$(AGENTICA) scripts/check_bindings.agc

# Needs `agentica scripts/fetch.agc all`.
test:
	AGENTICA=$(AGENTICA) python3 -m unittest tests.test_cli tests.test_api tests.test_bindings tests.test_fetch
