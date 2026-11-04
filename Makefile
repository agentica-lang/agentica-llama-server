# Needs Agentica 0.23.0 or later on PATH (or AGENTICA=/path/to/agentica).
AGENTICA ?= agentica

.PHONY: install check fmt-check test

install:
	$(AGENTICA) install

# The manifest names the llama.cpp libraries, so scripts/fetch-llama.sh runs first.
check:
	$(AGENTICA) check

fmt-check:
	$(AGENTICA) fmt --check server.agc smoke.agc src

# Needs scripts/fetch-llama.sh and scripts/fetch-model.sh.
test:
	AGENTICA=$(AGENTICA) python3 -m unittest tests.test_cli tests.test_api
