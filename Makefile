# =============================================================================
# flowlog-bench/Makefile — single source of entry points for perf workflows.
# =============================================================================
#
# Per AGENTS.md (lines 263-268):
#
#   "One Make target per task, no full-sweep orchestrator. Each script
#    already iterates over its (program × dataset) pairs internally; a
#    wrapper that calls all three would just be glue. If a consumer wants
#    'run everything,' it chains the three targets itself — same script-
#    library philosophy as the flowlog repo."
#
# Targets:
#   help          — print this help block
#   env           — one-time host bootstrap (souffle, duckdb, rust, …)
#   get-flowlog   — fetch + build flowlog at FLOWLOG_REF (default: main)
#   bench-one     — single (program × dataset) timing+RSS measurement
#   cross-engine  — flowlog vs. {soufflé, interpreter, …} at one ref
#   regression    — flowlog@BASE vs. flowlog@HEAD, A/B over commits
#   ldbc          — LDBC SNB timing / scaling
#   plot          — render speedup chart from results/
#   clean         — wipe results/ (keeps facts/ and flowlog/ caches)
#   distclean     — also wipes flowlog/ build cache (forces re-fetch)
#
# Standard call shapes (lines 235-244 of AGENTS.md):
#
#   make cross-engine                                    # default ref = main
#   FLOWLOG_REF=abc1234 make cross-engine                # specific commit
#   FLOWLOG_BASE=abc1234 FLOWLOG_HEAD=def5678 make regression
# =============================================================================

SHELL := /bin/bash

ROOT_DIR := $(shell pwd)
SCRIPTS  := $(ROOT_DIR)/scripts
TOOLS    := $(ROOT_DIR)/tools
CONFIG_DIR := $(ROOT_DIR)/config

# Default flowlog ref. Override on the command line:
#   FLOWLOG_REF=v0.5.0 make cross-engine
FLOWLOG_REF ?= main

# Default config file for cross_engine.sh / regression.sh.
CONFIG ?= $(CONFIG_DIR)/default.txt

.PHONY: help env get-flowlog bench-one cross-engine regression ldbc plot clean distclean

help:
	@awk 'NF==0 || /^[^#]/ {exit} {sub(/^# ?/,""); print}' $(firstword $(MAKEFILE_LIST))

env:
	@bash $(TOOLS)/env/env.sh

# -----------------------------------------------------------------------
# get-flowlog: fetch + build the engine at the chosen ref. Idempotent.
# Prints "<full_sha> <short_sha> <build_dir>" on the last stdout line.
# -----------------------------------------------------------------------
get-flowlog:
	@FLOWLOG_REF=$(FLOWLOG_REF) bash $(TOOLS)/get_flowlog.sh

# -----------------------------------------------------------------------
# bench-one: single (program × dataset) measurement.
#
# Usage:  make bench-one PROG=program_analysis/cspa.dl DATASET=cspa-httpd
# -----------------------------------------------------------------------
bench-one: get-flowlog
	@if [[ -z "$(PROG)" || -z "$(DATASET)" ]]; then \
		echo "ERROR: PROG and DATASET are required."; \
		echo "       e.g.  make bench-one PROG=program_analysis/cspa.dl DATASET=cspa-httpd"; \
		exit 2; \
	fi
	@read FULL SHORT BUILD < <(FLOWLOG_REF=$(FLOWLOG_REF) bash $(TOOLS)/get_flowlog.sh | tail -1); \
	 FLOWLOG_BIN="$$BUILD/target/release/flowlog-compiler" \
	 FLOWLOG_SRC_DIR="$$BUILD/src" \
	 bash $(SCRIPTS)/bench_one.sh "$(PROG)" "$(DATASET)"

# -----------------------------------------------------------------------
# cross-engine: flowlog vs. baselines (interpreter, souffle) at one ref.
#
# Usage:                  make cross-engine
#                         make cross-engine BASELINE=souffle CONFIG=config/default.txt
#                         FLOWLOG_REF=abc1234 make cross-engine
# -----------------------------------------------------------------------
BASELINE ?= souffle

cross-engine: get-flowlog
	@read FULL SHORT BUILD < <(FLOWLOG_REF=$(FLOWLOG_REF) bash $(TOOLS)/get_flowlog.sh | tail -1); \
	 FLOWLOG_BIN="$$BUILD/target/release/flowlog-compiler" \
	 FLOWLOG_SRC_DIR="$$BUILD/src" \
	 bash $(SCRIPTS)/cross_engine.sh --baseline=$(BASELINE) $(CONFIG)

# -----------------------------------------------------------------------
# regression: A/B between two flowlog refs. Both refs are fetched +
# built via get_flowlog.sh; binaries cached at flowlog/<short_sha>/.
#
# Usage:  FLOWLOG_BASE=abc1234 FLOWLOG_HEAD=def5678 make regression
# -----------------------------------------------------------------------
regression:
	@if [[ -z "$(FLOWLOG_BASE)" || -z "$(FLOWLOG_HEAD)" ]]; then \
		echo "ERROR: FLOWLOG_BASE and FLOWLOG_HEAD are required."; \
		echo "       e.g.  FLOWLOG_BASE=v0.5.0 FLOWLOG_HEAD=main make regression"; \
		exit 2; \
	fi
	@bash $(SCRIPTS)/regression.sh "$(FLOWLOG_BASE)" "$(FLOWLOG_HEAD)" "$(CONFIG)"

# -----------------------------------------------------------------------
# ldbc: LDBC SNB timing / scaling at one ref.
#
# Usage:  make ldbc                                    # default ref = main
#         FLOWLOG_REF=v0.5.0 make ldbc CONFIG=config/ldbc.txt
# -----------------------------------------------------------------------
ldbc: get-flowlog
	@read FULL SHORT BUILD < <(FLOWLOG_REF=$(FLOWLOG_REF) bash $(TOOLS)/get_flowlog.sh | tail -1); \
	 FLOWLOG_BIN="$$BUILD/target/release/flowlog-compiler" \
	 bash $(SCRIPTS)/ldbc.sh --config $(CONFIG_DIR)/ldbc.txt

# -----------------------------------------------------------------------
# plot: render the speedup chart from the most recent cross-engine CSV.
# -----------------------------------------------------------------------
plot:
	@python3 $(ROOT_DIR)/plotting/plot_speedup.py

# -----------------------------------------------------------------------
# clean / distclean
# -----------------------------------------------------------------------
clean:
	@rm -rf $(ROOT_DIR)/results
	@echo "wiped results/ (kept facts/ and flowlog/ caches)"

distclean: clean
	@rm -rf $(ROOT_DIR)/flowlog
	@echo "wiped flowlog/ build cache (next run will re-fetch + re-build)"
