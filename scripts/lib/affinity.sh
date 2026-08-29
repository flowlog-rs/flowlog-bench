#!/usr/bin/env bash
# Machine-aware CPU/NUMA placement shared by benchmark runners.

[[ -n "${FLOWLOG_BENCH_AFFINITY_LOADED:-}" ]] && return 0
FLOWLOG_BENCH_AFFINITY_LOADED=1

_bench_expand_list() {
    local item first last i
    IFS=',' read -ra _bench_items <<< "$1"
    for item in "${_bench_items[@]}"; do
        if [[ "$item" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            first="${BASH_REMATCH[1]}"; last="${BASH_REMATCH[2]}"
            for ((i=first; i<=last; i++)); do printf '%s\n' "$i"; done
        elif [[ "$item" =~ ^[0-9]+$ ]]; then
            printf '%s\n' "$item"
        else
            return 1
        fi
    done
}

# bench_affinity_reexec WORKER_ENV original argv...
# Resolves physical cores inside the current cpuset, then re-execs the runner
# under numactl. BENCH_AFFINITY_ACTIVE prevents recursion.
bench_affinity_reexec() {
    local worker_var="$1"; shift
    [[ -z "${BENCH_AFFINITY_ACTIVE:-}" ]] || return 0

    local explicitly_set=0
    [[ -v "$worker_var" ]] && explicitly_set=1
    local requested="${!worker_var:-32}"
    [[ "$requested" =~ ^[0-9]+$ ]] && (( requested > 0 )) || {
        echo "ERROR: $worker_var must be a positive integer (got: $requested)" >&2
        return 2
    }
    command -v lscpu >/dev/null 2>&1 || {
        echo "ERROR: lscpu is required for machine-aware benchmark affinity" >&2
        return 2
    }

    local allowed_spec
    allowed_spec="$(awk '/^Cpus_allowed_list:/ {print $2}' /proc/self/status)"
    [[ -n "$allowed_spec" ]] || { echo "ERROR: cannot read the current CPU allowance" >&2; return 2; }

    local -A allowed=() seen_core=() cpus_by_node=() count_by_node=()
    local cpu core node online key
    while read -r cpu; do allowed["$cpu"]=1; done < <(_bench_expand_list "$allowed_spec")
    while IFS=, read -r cpu core node online; do
        [[ "$cpu" =~ ^[0-9]+$ && "$core" =~ ^[0-9]+$ ]] || continue
        [[ "${online:-Y}" == Y && -n "${allowed[$cpu]:-}" ]] || continue
        [[ "$node" =~ ^[0-9]+$ ]] || node=0
        key="${node}:${core}"
        [[ -z "${seen_core[$key]:-}" ]] || continue
        seen_core["$key"]=1
        cpus_by_node["$node"]="${cpus_by_node[$node]:+${cpus_by_node[$node]},}${cpu}"
        count_by_node["$node"]=$(( ${count_by_node[$node]:-0} + 1 ))
    done < <(lscpu -p=CPU,CORE,NODE,ONLINE)

    local total=${#seen_core[@]}
    (( total > 0 )) || { echo "ERROR: no allowed online physical cores found" >&2; return 2; }
    local workers=$requested
    if (( workers > total )); then
        if (( explicitly_set )); then
            echo "ERROR: $worker_var=$workers exceeds the $total allowed physical cores (SMT siblings are excluded)" >&2
            return 2
        fi
        workers=$total
    fi

    local -a ranked_nodes=() selected_nodes=() selected_cpus=()
    if [[ -n "${BENCH_NUMA_NODES:-}" ]]; then
        while read -r node; do
            [[ -n "${count_by_node[$node]:-}" ]] || {
                echo "ERROR: BENCH_NUMA_NODES includes unavailable node $node" >&2; return 2;
            }
            ranked_nodes+=("$node")
        done < <(_bench_expand_list "$BENCH_NUMA_NODES")
    else
        while read -r node _; do ranked_nodes+=("$node"); done < <(
            for node in "${!count_by_node[@]}"; do printf '%s %s\n' "$node" "${count_by_node[$node]}"; done |
                sort -k2,2nr -k1,1n
        )
    fi

    local capacity=0
    for node in "${ranked_nodes[@]}"; do
        selected_nodes+=("$node")
        capacity=$((capacity + count_by_node[$node]))
        (( capacity >= workers )) && break
    done
    (( capacity >= workers )) || {
        echo "ERROR: selected NUMA nodes provide only $capacity physical cores; $workers requested" >&2
        return 2
    }

    if [[ -n "${BENCH_CPUS:-}" ]]; then
        while read -r cpu; do
            [[ -n "${allowed[$cpu]:-}" ]] || {
                echo "ERROR: BENCH_CPUS includes CPU $cpu outside Cpus_allowed_list=$allowed_spec" >&2; return 2;
            }
            selected_cpus+=("$cpu")
        done < <(_bench_expand_list "$BENCH_CPUS")
        ((${#selected_cpus[@]} >= workers)) || {
            echo "ERROR: BENCH_CPUS supplies ${#selected_cpus[@]} CPUs; $workers workers requested" >&2; return 2;
        }
    else
        local round index candidate
        for ((round=0; ${#selected_cpus[@]}<workers; round++)); do
            for node in "${selected_nodes[@]}"; do
                IFS=',' read -ra _bench_node_cpus <<< "${cpus_by_node[$node]}"
                candidate="${_bench_node_cpus[$round]:-}"
                [[ -n "$candidate" ]] && selected_cpus+=("$candidate")
                ((${#selected_cpus[@]} == workers)) && break
            done
        done
    fi

    local cpu_csv node_csv memory_policy
    cpu_csv="$(IFS=,; echo "${selected_cpus[*]:0:workers}")"
    node_csv="$(IFS=,; echo "${selected_nodes[*]}")"
    if ((${#selected_nodes[@]} == 1)); then memory_policy="membind:${selected_nodes[0]}"; else memory_policy="interleave:$node_csv"; fi

    printf -v "$worker_var" '%s' "$workers"
    export "$worker_var"
    export BENCH_AFFINITY_ACTIVE=1 BENCH_AFFINITY_CPUS="$cpu_csv" \
        BENCH_AFFINITY_NODES="$node_csv" BENCH_AFFINITY_MEMORY_POLICY="$memory_policy" \
        BENCH_TOPOLOGY_ALLOWED_CPUS="$allowed_spec" BENCH_TOPOLOGY_PHYSICAL_CORES="$total"

    if [[ "${BENCH_NO_PIN:-0}" == 1 ]]; then
        BENCH_AFFINITY_CPUS=unbound
        BENCH_AFFINITY_NODES=unbound
        BENCH_AFFINITY_MEMORY_POLICY=unbound
        export BENCH_AFFINITY_CPUS BENCH_AFFINITY_NODES BENCH_AFFINITY_MEMORY_POLICY
        return 0
    fi
    command -v numactl >/dev/null 2>&1 || {
        echo "ERROR: numactl is required for benchmark pinning (run: bash env.sh, or set BENCH_NO_PIN=1)" >&2
        return 2
    }
    echo "[affinity] workers=$workers physical_cores=$total cpus=$cpu_csv nodes=$node_csv memory=$memory_policy" >&2
    if ((${#selected_nodes[@]} == 1)); then
        exec numactl --physcpubind="$cpu_csv" --membind="${selected_nodes[0]}" bash "$0" "$@"
    else
        exec numactl --physcpubind="$cpu_csv" --interleave="$node_csv" bash "$0" "$@"
    fi
}
