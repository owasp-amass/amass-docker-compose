#!/bin/bash
# Run N learning passes of the NLP plugin against a target.
# Between passes: reset DB and restart engine, but KEEP nlp_learned.bin.
# Usage: learning_passes.sh <target> <passes> <timeout_min>
set -e

TARGET="${1:-owasp.org}"
PASSES="${2:-5}"
TIMEOUT="${3:-30}"
STACK="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS="$STACK/benchmark/learning_results"

mkdir -p "$RESULTS"

cd "$STACK"

echo "=== NLP Learning Test: $PASSES passes, target=$TARGET, timeout=${TIMEOUT}m ==="
echo ""

for i in $(seq 1 "$PASSES"); do
  echo "--- Pass $i / $PASSES ---"

  # Record nlp_learned.bin size before run
  learned_size_before=$(stat -c %s data/engine/nlp_learned.bin 2>/dev/null || echo 0)
  echo "  nlp_learned.bin before: ${learned_size_before} bytes"

  # Reset DB only (keep nlp_learned.bin)
  rm -f data/engine/assetdb.db
  docker compose restart engine > /dev/null 2>&1
  sleep 12

  engine_log_before=$(wc -l < logs/amass/engine/$(date -u +%Y-%m-%d)-amass-engine.log 2>/dev/null || echo 0)

  # Run NLP-only enum
  echo "  Starting enum at $(date) ..."
  docker compose run --rm enum -nlp -d "$TARGET" -timeout "$TIMEOUT" > /dev/null 2>&1
  echo "  Enum finished at $(date)"

  # Wait a moment for syslog to flush
  sleep 3

  # Record nlp_learned.bin size after run
  learned_size_after=$(stat -c %s data/engine/nlp_learned.bin 2>/dev/null || echo 0)
  learned_growth=$((learned_size_after - learned_size_before))
  echo "  nlp_learned.bin after:  ${learned_size_after} bytes (grew ${learned_growth} bytes)"

  # Count NLP activity from engine log (p.log lines: persist + generate)
  engine_log="logs/amass/engine/$(date -u +%Y-%m-%d)-amass-engine.log"
  if [ -f "$engine_log" ]; then
    engine_log_after=$(wc -l < "$engine_log")
    new_lines=$((engine_log_after - engine_log_before))
    persist_count=$(tail -n "$new_lines" "$engine_log" 2>/dev/null | grep -c "NLP learned delta persisted" || echo 0)
    nlp_active=$(tail -n "$new_lines" "$engine_log" 2>/dev/null | grep -c "NLP-Generator active" || echo 0)
  else
    persist_count=0
    nlp_active=0
  fi
  echo "  Engine log: NLP persist flushes=$persist_count, NLP-active events=$nlp_active"

  # Query SQLite for DNS-confirmed FQDNs
  if [ -f "data/engine/assetdb.db" ]; then
    fqdn_count=$(docker run --rm \
      -v "$STACK/data/engine:/data" \
      alpine sh -c "
        apk add --quiet sqlite 2>/dev/null
        sqlite3 /data/assetdb.db \"
          SELECT COUNT(DISTINCT json_extract(f.content, '$.name'))
          FROM entities f
          JOIN edges e ON e.from_entity_id = f.entity_id
          WHERE f.etype='FQDN'
            AND e.etype IN ('BasicDNSRelation','PrefDNSRelation')
            AND json_extract(f.content, '$.name') LIKE '%.${TARGET}';
        \"
      " 2>/dev/null || echo "?")
    echo "  DNS-confirmed FQDNs: $fqdn_count"

    # Save per-pass FQDN list
    docker run --rm \
      -v "$STACK/data/engine:/data" \
      alpine sh -c "
        apk add --quiet sqlite 2>/dev/null
        sqlite3 /data/assetdb.db \"
          SELECT DISTINCT json_extract(f.content, '$.name')
          FROM entities f
          JOIN edges e ON e.from_entity_id = f.entity_id
          WHERE f.etype='FQDN'
            AND e.etype IN ('BasicDNSRelation','PrefDNSRelation')
            AND json_extract(f.content, '$.name') LIKE '%.${TARGET}'
          ORDER BY 1;
        \"
      " 2>/dev/null > "$RESULTS/pass_${i}_fqdns.txt" || true
  else
    echo "  DNS-confirmed FQDNs: 0 (no DB)"
  fi

  echo ""
done

echo "=== Learning test complete ==="
echo ""
echo "Summary:"
for i in $(seq 1 "$PASSES"); do
  fqdns=$(wc -l < "$RESULTS/pass_${i}_fqdns.txt" 2>/dev/null || echo 0)
  echo "  Pass $i: $fqdns DNS-confirmed FQDNs"
done
