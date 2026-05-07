# =============================================================================
# flowlog-bench/Makefile — single source of entry points for perf workflows.
# =============================================================================
#
# Per AGENTS.md design principle 4 ("One Make target per task, no full-
# sweep orchestrator"): each script already iterates over its
# (program × dataset) pairs internally, so a wrapper that calls all
# three would just be glue. If a consumer wants "run everything," it
# chains the three targets itself — same script-library philosophy as
# the flowlog repo.
#
# Targets:
#   help                  — print this help block
#   env                   — one-time host bootstrap (souffle, duckdb, rust, …)
#   get-flowlog           — fetch + build flowlog at FLOWLOG_REF (default: main)
#   cross-engine          — flowlog vs. {soufflé, interpreter, …} at one ref
#   cross-flowlog-version — flowlog@BASE vs. flowlog@HEAD, A/B over commits
#   ldbc                  — LDBC SNB timing / scaling
#   plot                  — render speedup chart from results/
#   clean                 — wipe results/ (keeps facts/ and flowlog/ caches)
#   distclean             — also wipes flowlog/ build cache (forces re-fetch)
#
# Standard call shapes (see AGENTS.md, "Specifying which flowlog commit
# to bench"):
#
#   make cross-engine                                    # default ref = main
#   FLOWLOG_REF=abc1234 make cross-engine                # specific commit
#   FLOWLOG_BASE=abc1234 FLOWLOG_HEAD=def5678 make cross-flowlog-version
# =============================================================================

SHELL := /bin/bash

# --- Paths -------------------------------------------------------------------
ROOT_DIR   := $(shell pwd)
SCRIPTS    := $(ROOT_DIR)/scripts
TOOLS      := $(ROOT_DIR)/tools
CONFIG_DIR := $(ROOT_DIR)/config

# --- User-overridable defaults ----------------------------------------------
# Override on the command line, e.g.  FLOWLOG_REF=v0.5.0 make cross-engine
FLOWLOG_REF ?= main
ENGINES     ?= souffle
CONFIG      ?= $(CONFIG_DIR)/default.txt
# Separate slot for ldbc so the same Make session can drive cross-engine
# + ldbc without one inheriting the other's config.
LDBC_CONFIG ?= $(CONFIG_DIR)/ldbc.txt
PLOT_CSV    ?= $(ROOT_DIR)/results/benchmark/comparison_results.csv

.PHONY: help env get-flowlog cross-engine cross-flowlog-version \
        ldbc plot clean distclean

# -----------------------------------------------------------------------------
help:
	@awk 'NF==0 || /^[^#]/ {exit} {sub(/^# ?/,""); print}' $(firstword $(MAKEFILE_LIST))

env:
	@bash $(TOOLS)/env/env.sh

# -----------------------------------------------------------------------------
# get-flowlog: fetch + build the engine at the chosen ref. Idempotent.
# Prints "<full_sha> <short_sha> <build_dir>" on the last stdout line.
#
# The cross-engine / ldbc / cross-flowlog-version targets call this
# script in-recipe (not via a `make` dep) — the dep would be redundant
# since the recipe already has to read the script's output (FULL /
# SHORT / BUILD) to set FLOWLOG_BIN + FLOWLOG_RESOLVED_SHA.
#
# Standalone use is for cache-warming a ref before kicking off a long
# sweep:   FLOWLOG_REF=v0.5.0 make get-flowlog
# -----------------------------------------------------------------------------
get-flowlog:
	@FLOWLOG_REF=$(FLOWLOG_REF) bash $(SCRIPTS)/get_flowlog.sh

# -----------------------------------------------------------------------------
# cross-engine: flowlog-compiler vs. other engines at one ref.
#
# Usage:  make cross-engine
#         make cross-engine ENGINES=souffle,interpreter CONFIG=config/default.txt
#         FLOWLOG_REF=abc1234 make cross-engine
# -----------------------------------------------------------------------------
cross-engine:
	@read FULL SHORT BUILD < <(FLOWLOG_REF=$(FLOWLOG_REF) bash $(SCRIPTS)/get_flowlog.sh | tail -1); \
	 FLOWLOG_BIN="$$BUILD/target/release/flowlog-compiler" \
	 FLOWLOG_RESOLVED_SHA="$$FULL" \
	 bash $(SCRIPTS)/cross_engine.sh --engines=$(ENGINES) $(CONFIG)

# -----------------------------------------------------------------------------
# cross-flowlog-version: A/B between two flowlog refs. Both refs are
# fetched + built via get_flowlog.sh; binaries cached at flowlog/<short_sha>/.
# Dataset for each pair is downloaded into facts/ and cleaned after both
# refs are measured (skipped under KEEP_DATASETS=1).
#
# Usage:  FLOWLOG_BASE=abc1234 FLOWLOG_HEAD=def5678 make cross-flowlog-version
#         (add KEEP_DATASETS=1 if facts/ is a symlinked shared mount)
# -----------------------------------------------------------------------------
cross-flowlog-version:
	@if [[ -z "$(FLOWLOG_BASE)" || -z "$(FLOWLOG_HEAD)" ]]; then \
	    echo "ERROR: FLOWLOG_BASE and FLOWLOG_HEAD are required."; \
	    echo "       e.g.  FLOWLOG_BASE=v0.5.0 FLOWLOG_HEAD=main make cross-flowlog-version"; \
	    exit 2; \
	fi
	@bash $(SCRIPTS)/cross_flowlog_version.sh \
	    $(if $(filter 1,$(KEEP_DATASETS)),--keep-datasets,) \
	    "$(FLOWLOG_BASE)" "$(FLOWLOG_HEAD)" "$(CONFIG)"

# -----------------------------------------------------------------------------
# ldbc: LDBC SNB timing / scaling at one ref. Uses LDBC_CONFIG (NOT
# the generic CONFIG slot) so the same Make session can drive
# cross-engine + ldbc with their respective configs.
#
# Usage:  make ldbc                                       # default ref = main
#         FLOWLOG_REF=v0.5.0 make ldbc                    # at a specific commit
#         make ldbc LDBC_CONFIG=path/to/custom.txt        # custom config
# -----------------------------------------------------------------------------
ldbc:
	@read FULL SHORT BUILD < <(FLOWLOG_REF=$(FLOWLOG_REF) bash $(SCRIPTS)/get_flowlog.sh | tail -1); \
	 FLOWLOG_BIN="$$BUILD/target/release/flowlog-compiler" \
	 FLOWLOG_RESOLVED_SHA="$$FULL" \
	 bash $(SCRIPTS)/ldbc.sh --config $(LDBC_CONFIG)

# -----------------------------------------------------------------------------
# plot: render the 2-panel time + peak-RSS chart from a cross-engine CSV.
# Override the input via PLOT_CSV=<path>; default is the cross_engine.sh
# output file. Writes <stem>.{pdf,svg} next to the input.
# -----------------------------------------------------------------------------
plot:
	@if [[ ! -s "$(PLOT_CSV)" ]]; then \
	    echo "ERROR: no CSV at $(PLOT_CSV) — run \`make cross-engine\` first, or pass PLOT_CSV=<path>"; \
	    exit 2; \
	fi
	@python3 $(ROOT_DIR)/plot/plot_perf.py "$(PLOT_CSV)"

# -----------------------------------------------------------------------------
# clean / distclean
# -----------------------------------------------------------------------------
clean:
	@rm -rf $(ROOT_DIR)/results
	@echo "wiped results/ (kept facts/ and flowlog/ caches)"

distclean: clean
	@rm -rf $(ROOT_DIR)/flowlog
	@echo "wiped flowlog/ build cache (next run will re-fetch + re-build)"
