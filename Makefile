.PHONY: check fmt lint test vendor-check release-check live parity
NVIM ?= nvim
check: fmt lint test vendor-check
fmt:
	stylua --check $(wildcard lua tests plugin)
lint:
	selene $(wildcard lua tests plugin)
test:
	$(NVIM) --headless -u NONE -l tests/run.lua
# vendor-check and release-check need the nvim-plugins Dach one level up (../tools). A clone of
# this repo alone skips them loudly instead of failing with "can't open file".
DACH := ..
vendor-check:
	@if [ -f $(DACH)/tools/kit/vendor.py ]; then PYTHONDONTWRITEBYTECODE=1 python3 $(DACH)/tools/kit/vendor.py check .; \
	else echo "vendor-check: SKIPPED — no nvim-plugins Dach at $(DACH)/tools (it checks the vendored copies against their sources)"; fi
release-check:
	@if [ -f $(DACH)/tools/bibliothek/gate.py ]; then PYTHONDONTWRITEBYTECODE=1 python3 $(DACH)/tools/bibliothek/gate.py --repo . --seit-tag; \
	else echo "release-check: SKIPPED — no nvim-plugins Dach at $(DACH)/tools (Bibliothek gate)"; fi
# One run against a real embedding server (Ollama, LM Studio); not part of check. The line "live: exit N"
# carries the script's code (0 pass, 1 fail, 2 nothing measured); make itself exits 2 on any non-zero.
live:
	@$(NVIM) --headless -u NONE -l tests/live.lua; code=$$?; echo "live: exit $$code"; exit $$code
# Writer parity: the own index writer against a vault-rag index of the same notes (reads only, tests/parity.lua).
# PARITY_VAULT (a copy of a vault with _vaultrag/index.bin) and PARITY_URL are required; exit 0 parity, 1 deviation, 2 no valid measurement.
parity:
	@$(NVIM) --headless -u NONE -l tests/parity.lua; code=$$?; echo "parity: exit $$code"; exit $$code
