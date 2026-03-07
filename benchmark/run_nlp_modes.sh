#!/bin/bash
# Run only NLP benchmark modes (C' and C) against an existing results directory.
# Reuses ground_truth.txt and Mode A/B results already captured in the results dir,
# overwrites mode_Cprime_* and mode_C_* files, then regenerates the full report.
#
# Usage: run_nlp_modes.sh -d <domain> [-t <timeout_min>] [-w <wordlist>]

set -euo pipefail

readonly DEFAULT_TIMEOUT=180
readonly DEFAULT_WORDLIST="/.config/amass/wordlists/subdomains-top1mil-5000.txt"

usage() {
    cat <<EOF
USAGE
    $(basename "$0") -d <domain> [-t <timeout_min>] [-w <wordlist>]

DESCRIPTION
    Runs only Mode C' (NLP only) and Mode C (brute + NLP) using an existing
    benchmark results directory. Mode A/B results and ground truth are reused.

OPTIONS
    -d, --domain   <domain>   Target domain (required; must have existing results dir)
    -t, --timeout  <min>      Amass timeout per mode (default: $DEFAULT_TIMEOUT)
    -w, --wordlist <path>     Container path to wordlist (default: $DEFAULT_WORDLIST)
    -h, --help                Show this help and exit
EOF
}

TARGET=""
TIMEOUT="$DEFAULT_TIMEOUT"
WORDLIST="$DEFAULT_WORDLIST"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -d|--domain)  [[ $# -ge 2 ]] || { echo "Error: --domain requires argument" >&2; exit 1; }
                      TARGET="$2"; shift 2 ;;
        -t|--timeout) [[ $# -ge 2 ]] || { echo "Error: --timeout requires argument" >&2; exit 1; }
                      TIMEOUT="$2"; shift 2 ;;
        -w|--wordlist)[[ $# -ge 2 ]] || { echo "Error: --wordlist requires argument" >&2; exit 1; }
                      WORDLIST="$2"; shift 2 ;;
        *) echo "Error: unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

[[ -n "$TARGET" ]] || { echo "Error: -d <domain> is required." >&2; exit 1; }

STACK="$(cd "$(dirname "$0")/.." && pwd)"
DATE=$(date +%Y-%m-%d)
RUN_TS=$(date +%Y-%m-%dT%H:%M:%S)
RESULTS="$STACK/benchmark/results/${TARGET}_${DATE}"
BENCH_DIR="$STACK/benchmark"

[[ -d "$RESULTS" ]] || { echo "Error: results dir not found: $RESULTS" >&2; echo "Run benchmark.sh first to generate Mode A and B results." >&2; exit 1; }

cd "$STACK"

log()  { echo "[$(date +%H:%M:%S)] $*" | tee -a "$RESULTS/benchmark.log"; }

log "=== NLP modes only: target=$TARGET timeout=${TIMEOUT}m ==="

# ── helpers (copied from benchmark.sh) ───────────────────────────────────────

reset_state() {
    local keep_learned="${1:-false}"
    log "Resetting state (keep_learned=$keep_learned)..."
    rm -f data/engine/assetdb.db
    if [ "$keep_learned" != "true" ]; then
        rm -f data/engine/nlp_learned.bin
    fi
    docker compose restart engine > /dev/null 2>&1
    sleep 12
    local attempts=0
    until docker compose ps engine | grep -q "(healthy)"; do
        sleep 3
        attempts=$((attempts + 1))
        if [ $attempts -ge 10 ]; then
            log "WARNING: engine did not become healthy after reset"
            break
        fi
    done
}

query_fqdns() {
    local tgt="$1"
    docker run --rm \
        -v "$STACK/data/engine:/data" \
        alpine sh -c "
            apk add --quiet sqlite 2>/dev/null
            sqlite3 /data/assetdb.db \"
                SELECT DISTINCT json_extract(f.content, '$.name')
                FROM entities f
                JOIN edges e ON e.from_entity_id = f.entity_id
                WHERE f.etype = 'FQDN'
                  AND e.etype IN ('BasicDNSRelation','PrefDNSRelation')
                  AND json_extract(f.content, '$.name') LIKE '%.${tgt}'
                ORDER BY 1;
            \"
        " 2>/dev/null
}

run_mode() {
    local label="$1"; shift
    local desc="$1"; shift
    local outfile="$RESULTS/mode_${label}_fqdns.txt"
    local logfile="$RESULTS/mode_${label}_enum.log"
    local start_ts
    start_ts=$(date +%s)

    log "--- Mode $label ($desc) starting at $(date +%H:%M:%S) ---"
    docker compose run --rm enum "$@" -d "$TARGET" -timeout "$TIMEOUT" \
        > "$logfile" 2>&1 || true

    local end_ts elapsed mins secs runtime_str
    end_ts=$(date +%s)
    elapsed=$(( end_ts - start_ts ))
    mins=$(( elapsed / 60 ))
    secs=$(( elapsed % 60 ))
    runtime_str=$(printf "%dm%02ds" $mins $secs)
    echo "$runtime_str" > "$RESULTS/mode_${label}_runtime.txt"
    echo "$elapsed"     > "$RESULTS/mode_${label}_elapsed.txt"
    log "Mode $label finished in $runtime_str"

    query_fqdns "$TARGET" > "$outfile" || true
    local found
    found=$(wc -l < "$outfile")
    log "Mode $label: $found DNS-confirmed FQDNs"
}

# ── ground truth (reuse existing) ────────────────────────────────────────────

GT=0
if [ -f "$RESULTS/ground_truth.txt" ]; then
    GT=$(wc -l < "$RESULTS/ground_truth.txt")
    log "Reusing ground truth: $GT FQDNs"
else
    log "WARNING: ground_truth.txt not found — recall metrics unavailable"
fi

# ── Mode C': NLP only ─────────────────────────────────────────────────────────

reset_state false
run_mode "Cprime" "NLP only" -nlp

# ── Mode C: brute + NLP ───────────────────────────────────────────────────────

reset_state false
run_mode "C" "brute + NLP" -brute -nlp -w "$WORDLIST"

# ── report ────────────────────────────────────────────────────────────────────

log "Generating report ..."
bash "$BENCH_DIR/analyze_results.sh" \
    "$TARGET" "$RESULTS" "$WORDLIST" "$TIMEOUT" "$RUN_TS" "$GT"

log "=== NLP modes complete. Report: $RESULTS/benchmark-results.md ==="
