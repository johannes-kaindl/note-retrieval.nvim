.PHONY: check fmt lint test vendor-check release-check live parity demo
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
# README demo (docs/demo/demo.tape): vhs records, ffmpeg makes the 20 fps GIF and MP4 of docs/images/. Needs vhs, ffmpeg
# and an embedding server (Ollama with qwen3-embedding:0.6b by default; override with NOTE_RETRIEVAL_DEMO_URL and
# NOTE_RETRIEVAL_DEMO_MODEL). The recording runs in a throw-away copy of the fixture vault and throw-away XDG folders.
NOTE_RETRIEVAL_DEMO_URL ?= http://localhost:11434
NOTE_RETRIEVAL_DEMO_MODEL ?= qwen3-embedding:0.6b
export NOTE_RETRIEVAL_DEMO_URL NOTE_RETRIEVAL_DEMO_MODEL
demo:
	@curl -sf -m 5 $(NOTE_RETRIEVAL_DEMO_URL)/v1/models >/dev/null || { echo "demo: no embedding server at $(NOTE_RETRIEVAL_DEMO_URL) — start one, see docs/demo/init.lua"; exit 2; }
	vhs docs/demo/demo.tape
	ffmpeg -v error -y -i docs/demo/.build/demo.mp4 -vf "fps=20,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5" docs/images/demo.gif
	ffmpeg -v error -y -i docs/demo/.build/demo.mp4 -vf fps=20 -c:v libx264 -pix_fmt yuv420p -movflags +faststart docs/images/demo.mp4
