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
#   help                       — print this help block
#   env                        — one-time host bootstrap (souffle, duckdb, rust, …)
#   get-flowlog                — fetch + build flowlog at FLOWLOG_REF (default: main)
#   cross-engine               — flowlog vs. {soufflé, interpreter, …} at one ref
#   cross-flowlog-version      — flowlog@BASE vs. flowlog@HEAD, A/B over commits
#   gen-joinorder-variants     — regenerate join-order variant .dl files
#   cross-joinorder            — sweep every join-order variant per (program, ds)
#   joinorder-summary          — per-pair fastest/median/slowest report
#   archive-joinorder          — snapshot results/joinorder/ to docs/historical/
#   ldbc                       — LDBC SNB timing / scaling
#   plot                       — render speedup chart from results/
#   clean                      — wipe results/ (keeps facts/ and flowlog/ caches)
#   distclean                  — also wipes flowlog/ build cache (forces re-fetch)
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
CONFIG_DIR := $(ROOT_DIR)/config

# --- User-overridable defaults ----------------------------------------------
# Override on the command line, e.g.  FLOWLOG_REF=v0.5.0 make cross-engine
FLOWLOG_REF ?= main
ENGINES     ?= souffle
CONFIG      ?= $(CONFIG_DIR)/default.txt
# Separate slot for joinorder so cross-engine and cross-joinorder can
# point at different (program, dataset) lists in the same Make session.
JOINORDER_CONFIG ?= $(CONFIG_DIR)/joinorder.txt
# Separate slot for ldbc so the same Make session can drive cross-engine
# + ldbc without one inheriting the other's config.
LDBC_CONFIG ?= $(CONFIG_DIR)/ldbc.txt
PLOT_CSV    ?= $(ROOT_DIR)/results/benchmark/comparison_results.csv

.PHONY: help env get-flowlog cross-engine cross-flowlog-version \
        cross-joinorder gen-joinorder-variants joinorder-summary \
        archive-joinorder \
        ldbc plot clean distclean

# -----------------------------------------------------------------------------
help:
	@awk 'NF==0 || /^[^#]/ {exit} {sub(/^# ?/,""); print}' $(firstword $(MAKEFILE_LIST))

env:
	@bash $(ROOT_DIR)/env.sh

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
# gen-joinorder-variants: regenerate per-program join-order variants
# under programs/oracle/flowlog/<stem>/. Idempotent — wipes stale
# variants in each <stem>/ before re-emitting.
# -----------------------------------------------------------------------------
gen-joinorder-variants:
	@python3 $(SCRIPTS)/joinorder/gen_joinorder_variants.py --all

# -----------------------------------------------------------------------------
# cross-joinorder: sweep all join-order variants per (program, dataset)
# pair from JOINORDER_CONFIG. Defaults to config/joinorder.txt (the
# plan-sensitive subset). For fast research-loop iteration, point at
# config/quick_joinorder.txt instead.
#
# Usage:  make cross-joinorder
#         make cross-joinorder JOINORDER_CONFIG=config/quick_joinorder.txt
#         FLOWLOG_REF=abc1234 make cross-joinorder
# -----------------------------------------------------------------------------
cross-joinorder:
	@read FULL SHORT BUILD < <(FLOWLOG_REF=$(FLOWLOG_REF) bash $(SCRIPTS)/get_flowlog.sh | tail -1); \
	 FLOWLOG_BIN="$$BUILD/target/release/flowlog-compiler" \
	 FLOWLOG_RESOLVED_SHA="$$FULL" \
	 bash $(SCRIPTS)/joinorder/cross_joinorder.sh $(JOINORDER_CONFIG)

# -----------------------------------------------------------------------------
# joinorder-summary: per-pair fastest/median/slowest + default percentile.
# Pass filter substrings to narrow output:  make joinorder-summary FILTER=andersen
# -----------------------------------------------------------------------------
joinorder-summary:
	@python3 $(SCRIPTS)/joinorder/joinorder_summary.py $(FILTER)

# -----------------------------------------------------------------------------
# archive-joinorder: snapshot results/joinorder/ into docs/historical/.
# Captures pair CSVs + a regenerated SUMMARY.md + a README with run
# conditions (flowlog SHA, host, sysctl, workers). Does NOT delete the
# source or git-add — prints the suggested commit command.
#
# Usage:  make archive-joinorder
#         make archive-joinorder ARCHIVE_FORCE=1   # overwrite existing snapshot
# -----------------------------------------------------------------------------
archive-joinorder:
	@python3 $(SCRIPTS)/joinorder/archive_joinorder.py \
	    $(if $(filter 1,$(ARCHIVE_FORCE)),--force,)

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
