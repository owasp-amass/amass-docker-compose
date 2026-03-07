#!/bin/bash
# NLP Benchmark — Run all four enumeration modes against a target domain and
# produce a structured Markdown report comparing passive, brute-force, NLP-only,
# and combined (brute + NLP) discovery.

set -euo pipefail

readonly VERSION="1.0.0"
readonly DEFAULT_TIMEOUT=60
readonly DEFAULT_WORDLIST="/.config/amass/wordlists/subdomains-top1mil-5000.txt"

# ── usage ─────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF

USAGE
    $(basename "$0") [OPTIONS] <domain>
    $(basename "$0") [OPTIONS] -d <domain>

DESCRIPTION
    Runs four enumeration modes against a target domain, queries DNS-confirmed
    FQDNs from the SQLite database after each run, and generates a Markdown
    report comparing recall, runtime, and exclusive discoveries.

    Modes:
      A  passive only          no flags
      B  brute force           -brute -w <wordlist>
      C' NLP only              -nlp
      C  brute + NLP           -brute -nlp -w <wordlist>

    Results are saved to:
      benchmark/results/<domain>_<date>/

    Report is written to:
      benchmark/results/<domain>_<date>/benchmark-results.md

OPTIONS
    -d, --domain   <domain>   Target domain to enumerate  (required)
    -t, --timeout  <min>      Amass timeout per mode in minutes
                              (default: $DEFAULT_TIMEOUT)
    -w, --wordlist <path>     Container path to brute-force wordlist
                              (default: $DEFAULT_WORDLIST)
    -h, --help                Show this help message and exit
    -V, --version             Show version and exit

EXAMPLES
    $(basename "$0") owasp.org
    $(basename "$0") -d apache.org -t 90
    $(basename "$0") -d example.com -t 60 -w /.config/amass/wordlists/subdomains-top1mil-20000.txt

EOF
}

# ── argument parsing ──────────────────────────────────────────────────────────

TARGET=""
TIMEOUT="$DEFAULT_TIMEOUT"
WORDLIST="$DEFAULT_WORDLIST"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage; exit 0 ;;
        -V|--version)
            echo "$(basename "$0") version $VERSION"; exit 0 ;;
        -d|--domain)
            [[ $# -ge 2 ]] || { echo "Error: --domain requires an argument." >&2; exit 1; }
            TARGET="$2"; shift 2 ;;
        -t|--timeout)
            [[ $# -ge 2 ]] || { echo "Error: --timeout requires an argument." >&2; exit 1; }
            TIMEOUT="$2"; shift 2 ;;
        -w|--wordlist)
            [[ $# -ge 2 ]] || { echo "Error: --wordlist requires an argument." >&2; exit 1; }
            WORDLIST="$2"; shift 2 ;;
        --)
            shift; break ;;
        -*)
            echo "Error: unknown option: $1" >&2
            echo "Run '$(basename "$0") --help' for usage." >&2
            exit 1 ;;
        *)
            if [[ -z "$TARGET" ]]; then
                TARGET="$1"; shift
            else
                echo "Error: unexpected argument: $1" >&2
                echo "Run '$(basename "$0") --help' for usage." >&2
                exit 1
            fi ;;
    esac
done

if [[ -z "$TARGET" ]]; then
    echo "Error: <domain> is required." >&2
    echo "Run '$(basename "$0") --help' for usage." >&2
    exit 1
fi

STACK="$(cd "$(dirname "$0")/.." && pwd)"
DATE=$(date +%Y-%m-%d)
RUN_TS=$(date +%Y-%m-%dT%H:%M:%S)
RESULTS="$STACK/benchmark/results/${TARGET}_${DATE}"
mkdir -p "$RESULTS"

BENCH_DIR="$STACK/benchmark"
cd "$STACK"

# ── logging ───────────────────────────────────────────────────────────────────

log()  { echo "[$(date +%H:%M:%S)] $*" | tee -a "$RESULTS/benchmark.log"; }
logn() { printf "[$(date +%H:%M:%S)] %s" "$*" | tee -a "$RESULTS/benchmark.log"; }

log "=== NLP Benchmark: target=$TARGET timeout=${TIMEOUT}m wordlist=$(basename "$WORDLIST") ==="
log "Results dir: $RESULTS"

# ── helpers ───────────────────────────────────────────────────────────────────

reset_state() {
    local keep_learned="${1:-false}"
    log "Resetting state (keep_learned=$keep_learned)..."
    rm -f data/engine/assetdb.db
    if [ "$keep_learned" != "true" ]; then
        rm -f data/engine/nlp_learned.bin
    fi
    docker compose restart engine > /dev/null 2>&1
    sleep 12
    # Verify engine is healthy
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
    # Extract DNS-confirmed FQDNs from the current SQLite DB.
    # A FQDN is "confirmed" if it has a BasicDNSRelation or PrefDNSRelation edge.
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
    local label="$1"; shift     # A, B, Cprime, C
    local desc="$1"; shift      # human description
    local outfile="$RESULTS/mode_${label}_fqdns.txt"
    local logfile="$RESULTS/mode_${label}_enum.log"
    local start_ts
    start_ts=$(date +%s)

    log "--- Mode $label ($desc) starting at $(date +%H:%M:%S) ---"
    docker compose run --rm enum "$@" -d "$TARGET" -timeout "$TIMEOUT" \
        > "$logfile" 2>&1 || true

    local end_ts
    end_ts=$(date +%s)
    local elapsed=$(( end_ts - start_ts ))
    local mins=$(( elapsed / 60 ))
    local secs=$(( elapsed % 60 ))
    local runtime_str
    runtime_str=$(printf "%dm%02ds" $mins $secs)
    echo "$runtime_str" > "$RESULTS/mode_${label}_runtime.txt"
    echo "$elapsed"     > "$RESULTS/mode_${label}_elapsed.txt"
    log "Mode $label finished in $runtime_str"

    # Extract DNS-confirmed FQDNs from the DB
    query_fqdns "$TARGET" > "$outfile" || true
    local found
    found=$(wc -l < "$outfile")
    log "Mode $label: $found DNS-confirmed FQDNs"
}

# ── ground truth ──────────────────────────────────────────────────────────────

log "Fetching ground truth from crt.sh for $TARGET ..."
if curl -sf "https://crt.sh/?q=%.${TARGET}&output=json" \
    | jq -r '.[].name_value' \
    | sed 's/\*\.//g' \
    | sort -u > "$RESULTS/ground_truth.txt"; then
    GT=$(wc -l < "$RESULTS/ground_truth.txt")
    log "Ground truth: $GT FQDNs"
else
    log "WARNING: crt.sh fetch failed — recall metrics will be unavailable"
    touch "$RESULTS/ground_truth.txt"
    GT=0
fi

# ── Mode A: passive ───────────────────────────────────────────────────────────

reset_state false
run_mode "A" "passive only"

# ── Mode B: brute force ───────────────────────────────────────────────────────

reset_state false
run_mode "B" "brute force" -brute -w "$WORDLIST"

# ── Mode C': NLP only ─────────────────────────────────────────────────────────

reset_state false
run_mode "Cprime" "NLP only" -nlp

# ── Mode C: brute + NLP combined ─────────────────────────────────────────────

reset_state false
run_mode "C" "brute + NLP" -brute -nlp -w "$WORDLIST"

# ── report ────────────────────────────────────────────────────────────────────

log "Generating report ..."
bash "$BENCH_DIR/analyze_results.sh" \
    "$TARGET" "$RESULTS" "$WORDLIST" "$TIMEOUT" "$RUN_TS" "$GT"

log "=== Benchmark complete. Report: $RESULTS/benchmark-results.md ==="
