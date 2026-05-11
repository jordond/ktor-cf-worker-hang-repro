#!/usr/bin/env bash
# End-to-end test of the Ktor-on-Cloudflare-Workers hang reproduction.
#
# Builds the worker, boots wrangler dev (local miniflare), runs a
# concurrent burst against it, counts how many responses contain the
# "Workers runtime canceled this request" hang body, prints a summary,
# tears wrangler down.
#
# Usage:
#   ./test-repro.sh                  # Ktor path, reproduces the hang
#   ./test-repro.sh --native         # native fetch baseline, hang-free
#   ./test-repro.sh --remote         # hit deployed worker on Cloudflare prod
#                                    #   (no local build, no wrangler dev)
#                                    #   Override URL: REMOTE_URL=https://your.worker.tld ./test-repro.sh --remote
#   ./test-repro.sh --suite          # full matrix: warmup, local ktor/native,
#                                    #   remote ktor (N samples), remote native;
#                                    #   writes suite-report-<ts>.md
#   ./test-repro.sh -n 60            # 60 concurrent requests
#   ./test-repro.sh --samples 5      # samples per remote variant in --suite (default 3)
#   ./test-repro.sh -p 8788          # bind wrangler on a different port
#   ./test-repro.sh -s 10            # also run N sequential requests first
#   ./test-repro.sh --keep           # leave wrangler running on exit (for poking)
#   ./test-repro.sh --skip-build     # reuse the existing compileSync output
#
# Exit status:
#   0  burst saw at least one hang (bug reproduced on Ktor path)
#      or burst saw zero hangs when --native was passed (expected baseline)
#      or --suite saw expected outcomes for all variants
#   1  expected reproduction did not occur (investigate)
#   2  environment / setup failure (build, wrangler, etc.)

set -uo pipefail

cd "$(dirname "$0")"

# ---- args ----
CONCURRENT=30
SEQUENTIAL=0
PORT=8787
KEEP=0
SKIP_BUILD=0
NATIVE=0
REMOTE=0
SUITE=0
SAMPLES=3
REMOTE_URL="${REMOTE_URL:-https://ktor-hang.jordond.dev}"
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--concurrent) CONCURRENT=$2; shift 2;;
        -s|--sequential) SEQUENTIAL=$2; shift 2;;
        -p|--port) PORT=$2; shift 2;;
        --samples) SAMPLES=$2; shift 2;;
        --keep) KEEP=1; shift;;
        --skip-build) SKIP_BUILD=1; shift;;
        --native) NATIVE=1; shift;;
        --remote) REMOTE=1; shift;;
        --suite) SUITE=1; shift;;
        -h|--help) sed -n '2,/^$/p' "$0"; exit 0;;
        *) echo "unknown arg: $1" >&2; exit 2;;
    esac
done

if [ "$SUITE" -eq 1 ] && { [ "$NATIVE" -eq 1 ] || [ "$REMOTE" -eq 1 ]; }; then
    echo "--suite is not compatible with --native or --remote" >&2
    exit 2
fi

WORK_DIR=$(mktemp -d -t ktor-cf-hang-repro.XXXXXX)
LOG_FILE="$WORK_DIR/wrangler-dev.log"
WRANGLER_PID=""

# Recursively collect descendants of a pid, deepest first, then kill.
# wrangler spawns intermediate node processes that fork workerd; if we
# only SIGTERM the top process the workerd grandchild gets reparented to
# init and keeps the port bound.
kill_tree() {
    local pid=$1
    local sig=${2:-TERM}
    local child
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        kill_tree "$child" "$sig"
    done
    kill "-$sig" "$pid" 2>/dev/null || true
}

# Fallback: kill any process still listening on the test port.
kill_port_listeners() {
    local port=$1
    local pids
    pids=$(lsof -ti ":$port" 2>/dev/null) || return 0
    [ -z "$pids" ] && return 0
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null || true
    sleep 0.5
    pids=$(lsof -ti ":$port" 2>/dev/null) || return 0
    [ -z "$pids" ] && return 0
    # shellcheck disable=SC2086
    kill -KILL $pids 2>/dev/null || true
}

stop_wrangler() {
    if [ -z "${WRANGLER_PID}" ]; then return; fi
    kill_tree "$WRANGLER_PID" TERM
    for _ in 1 2 3 4 5; do
        if ! kill -0 "$WRANGLER_PID" 2>/dev/null; then break; fi
        sleep 0.2
    done
    kill_tree "$WRANGLER_PID" KILL
    kill_port_listeners "$PORT"
    WRANGLER_PID=""
}

cleanup() {
    if [ "$KEEP" -eq 1 ] && [ -n "${WRANGLER_PID}" ]; then
        echo
        echo "Leaving wrangler dev running on http://localhost:${PORT} (PID ${WRANGLER_PID})."
        echo "Log: $LOG_FILE"
        echo "Stop with: kill ${WRANGLER_PID}"
        return
    fi
    stop_wrangler
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'echo "interrupted"; exit 130' INT TERM

step() { printf '\n=== %s ===\n' "$*"; }

# ---- pre-flight ----
step "pre-flight"
command -v curl >/dev/null  || { echo "curl not on PATH"; exit 2; }
NEED_LOCAL=0
if [ "$REMOTE" -eq 0 ] || [ "$SUITE" -eq 1 ]; then
    NEED_LOCAL=1
fi
if [ "$NEED_LOCAL" -eq 1 ]; then
    command -v node >/dev/null  || { echo "node not on PATH"; exit 2; }
    command -v npm >/dev/null   || { echo "npm not on PATH"; exit 2; }
    [ -f ./gradlew ] || { echo "./gradlew missing, wrong directory?"; exit 2; }
    if [ ! -x ./node_modules/.bin/wrangler ]; then
        echo "wrangler not installed; running npm install"
        npm install --silent || { echo "npm install failed"; exit 2; }
    fi
fi
WRANGLER="./node_modules/.bin/wrangler"

# ---- build (skipped for pure --remote runs) ----
if [ "$NEED_LOCAL" -eq 1 ] && [ "$SKIP_BUILD" -eq 0 ]; then
    step "build :jsProductionExecutableCompileSync"
    ./gradlew jsProductionExecutableCompileSync --quiet || { echo "gradle build failed"; exit 2; }
fi
if [ "$NEED_LOCAL" -eq 1 ]; then
    BUNDLE="build/compileSync/js/main/productionExecutable/kotlin/ktor-cf-worker-hang-repro.mjs"
    [ -f "$BUNDLE" ] || { echo "bundle missing at $BUNDLE, rebuild?"; exit 2; }
fi

# ---- helpers ----
classify_body() {
    local body_file=$1
    if [ ! -s "$body_file" ]; then echo "empty"; return; fi
    # Local miniflare returns "...canceled this request..." for 1101.
    # Real Cloudflare edge returns the short form "error code: 1101".
    if grep -q "canceled this request\|error code: 1101" "$body_file"; then echo "hang"; return; fi
    if grep -q "^EXC:" "$body_file"; then echo "exception"; return; fi
    echo "ok"
}

boot_wrangler() {
    "$WRANGLER" dev --local --port "$PORT" >"$LOG_FILE" 2>&1 &
    WRANGLER_PID=$!
    local ready=0
    for _ in $(seq 1 60); do
        if grep -q "Ready on" "$LOG_FILE" 2>/dev/null; then ready=1; break; fi
        if ! kill -0 "$WRANGLER_PID" 2>/dev/null; then
            echo "wrangler dev exited before becoming ready. log tail:"
            tail -30 "$LOG_FILE"
            exit 2
        fi
        sleep 0.5
    done
    if [ "$ready" -ne 1 ]; then
        echo "wrangler dev did not become ready within 30s. log tail:"
        tail -30 "$LOG_FILE"
        exit 2
    fi
    echo "wrangler ready (pid $WRANGLER_PID, log $LOG_FILE)"
}

# run_burst <url> <concurrent> <label>
# Writes per-request results to $WORK_DIR/<label>/results.tsv and bodies
# to $WORK_DIR/<label>/burst_N.body. Emits one TSV line on stdout:
#   <label> <url> <hangs> <ok> <exception> <empty> <total>
run_burst() {
    local url=$1
    local concurrent=$2
    local label=$3
    local sub="$WORK_DIR/$label"
    mkdir -p "$sub"
    local results="$sub/results.tsv"
    : > "$results"

    local pids=()
    local i
    for i in $(seq 1 "$concurrent"); do
        (
            local body="$sub/burst_${i}.body"
            local out
            out=$(curl -sS -m 30 -o "$body" \
                -w '%{http_code}\t%{time_total}' "$url" 2>/dev/null)
            printf '%s\t%s\t%s\n' "$i" "$out" "$(classify_body "$body")" >> "$results"
        ) &
        pids+=($!)
    done
    local pid
    for pid in "${pids[@]}"; do wait "$pid"; done

    local h=0 o=0 e=0 m=0 total=0
    while IFS=$'\t' read -r _ _ _ kind; do
        total=$((total+1))
        case "$kind" in
            hang) h=$((h+1));;
            ok) o=$((o+1));;
            exception) e=$((e+1));;
            empty) m=$((m+1));;
        esac
    done < "$results"
    printf '%s\t%s\t%d\t%d\t%d\t%d\t%d\n' "$label" "$url" "$h" "$o" "$e" "$m" "$total"
}

# print_burst_table <label>
print_burst_table() {
    local label=$1
    local results="$WORK_DIR/$label/results.tsv"
    sort -n "$results" | awk -F'\t' '{ printf "  %3d  http=%s  time=%-8s  body=%s\n", $1, $2, $3, $4 }'
}

# run_sequential <url> <n> <label>
# Emits one TSV line: <label> hangs ok other total
run_sequential() {
    local url=$1
    local n=$2
    local label=$3
    local sub="$WORK_DIR/$label"
    mkdir -p "$sub"
    local h=0 o=0 x=0
    local i body http kind
    for i in $(seq 1 "$n"); do
        body="$sub/seq_${i}.body"
        http=$(curl -sS -m 15 -o "$body" -w '%{http_code}' "$url" || echo "000")
        kind=$(classify_body "$body")
        case "$kind" in
            hang) h=$((h+1));;
            ok) o=$((o+1));;
            *) x=$((x+1));;
        esac
        printf '  %2d  http=%s  body=%s\n' "$i" "$http" "$kind"
    done
    printf '%s\t%d\t%d\t%d\t%d\n' "$label" "$h" "$o" "$x" "$n"
}

############################################################################
# Suite mode: full matrix + markdown report.
############################################################################
if [ "$SUITE" -eq 1 ]; then
    REPORT_FILE="$(pwd)/suite-report-$(date -u +%Y%m%d-%H%M%S).md"
    SUITE_RESULTS="$WORK_DIR/suite.tsv"
    : > "$SUITE_RESULTS"
    WARMUP_RESULT=""
    WARMUP_N=3
    LOCAL_BASE="http://localhost:${PORT}"

    step "boot wrangler dev on :${PORT}"
    boot_wrangler

    step "warmup: sequential x${WARMUP_N} against ${LOCAL_BASE}/"
    WARMUP_RESULT=$(run_sequential "${LOCAL_BASE}/" "$WARMUP_N" "warmup-local-ktor" | tail -1)

    step "local Ktor (concurrent x${CONCURRENT})"
    line=$(run_burst "${LOCAL_BASE}/" "$CONCURRENT" "local-ktor")
    echo "$line" >> "$SUITE_RESULTS"
    print_burst_table "local-ktor"
    echo "  -> $line"

    step "local native (concurrent x${CONCURRENT})"
    line=$(run_burst "${LOCAL_BASE}/native" "$CONCURRENT" "local-native")
    echo "$line" >> "$SUITE_RESULTS"
    echo "  -> $line"

    step "tearing down wrangler before remote burst"
    stop_wrangler

    for i in $(seq 1 "$SAMPLES"); do
        step "remote Ktor sample ${i}/${SAMPLES} (concurrent x${CONCURRENT})"
        line=$(run_burst "${REMOTE_URL}/" "$CONCURRENT" "remote-ktor-${i}")
        echo "$line" >> "$SUITE_RESULTS"
        echo "  -> $line"
    done

    step "remote native (concurrent x${CONCURRENT})"
    line=$(run_burst "${REMOTE_URL}/native" "$CONCURRENT" "remote-native")
    echo "$line" >> "$SUITE_RESULTS"
    echo "  -> $line"

    # ---- aggregate ----
    # awk-fu: extract first remote-ktor-* hang counts and average them.
    REMOTE_KTOR_AVG=$(awk -F'\t' '$1 ~ /^remote-ktor-/ { s+=$3; n++ } END { if (n>0) printf "%.1f", s/n; else print "n/a" }' "$SUITE_RESULTS")
    REMOTE_KTOR_SAMPLES=$(awk -F'\t' '$1 ~ /^remote-ktor-/ { printf "%s%s", (n++ ? ", " : ""), $3 } END { print "" }' "$SUITE_RESULTS")
    LOCAL_KTOR=$(awk -F'\t' '$1 == "local-ktor" { print $3 }' "$SUITE_RESULTS")
    LOCAL_NATIVE=$(awk -F'\t' '$1 == "local-native" { print $3 }' "$SUITE_RESULTS")
    REMOTE_NATIVE=$(awk -F'\t' '$1 == "remote-native" { print $3 }' "$SUITE_RESULTS")
    WARMUP_OK=$(echo "$WARMUP_RESULT" | awk -F'\t' '{print $3}')
    WARMUP_TOTAL=$(echo "$WARMUP_RESULT" | awk -F'\t' '{print $5}')

    SAMPLE_HANG_BODY=""
    for d in "$WORK_DIR/local-ktor" "$WORK_DIR"/remote-ktor-*; do
        candidate=$(grep -l "canceled this request\|error code: 1101" "$d"/burst_*.body 2>/dev/null | head -1 || true)
        if [ -n "$candidate" ]; then
            SAMPLE_HANG_BODY=$(head -c 600 "$candidate")
            break
        fi
    done

    # ---- write report ----
    NOW_UTC=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
    COMPAT_DATE=$(grep '"compatibility_date"' wrangler.json | sed -E 's/.*"compatibility_date":[[:space:]]*"([^"]+)".*/\1/')

    {
        echo "# Ktor JS HttpClient hang on Cloudflare Workers, suite report"
        echo
        echo "Generated: $NOW_UTC"
        echo
        echo "Configuration:"
        echo "- Concurrent per burst: $CONCURRENT"
        echo "- Remote samples: $SAMPLES"
        echo "- Local wrangler port: $PORT"
        echo "- Remote URL: $REMOTE_URL"
        echo "- compatibility_date: $COMPAT_DATE"
        echo
        echo "## Sequential warmup (local Ktor /)"
        echo
        echo "${WARMUP_OK:-0}/${WARMUP_TOTAL:-0} ok. Sequential requests do not reproduce the hang; the bug is concurrency-bound."
        echo
        echo "## Burst results"
        echo
        echo "| variant | hangs | ok | exception | empty | total |"
        echo "|---|---:|---:|---:|---:|---:|"
        while IFS=$'\t' read -r label url h o e m total; do
            printf '| %s | %d | %d | %d | %d | %d |\n' "$label" "$h" "$o" "$e" "$m" "$total"
        done < "$SUITE_RESULTS"
        echo
        echo "## Aggregate"
        echo
        echo "| variant | hangs | total |"
        echo "|---|---:|---:|"
        printf '| Local Ktor | %s | %s |\n' "$LOCAL_KTOR" "$CONCURRENT"
        printf '| Local native | %s | %s |\n' "$LOCAL_NATIVE" "$CONCURRENT"
        printf '| Remote Ktor (avg of %s) | %s | %s |\n' "$SAMPLES" "$REMOTE_KTOR_AVG" "$CONCURRENT"
        printf '| Remote native | %s | %s |\n' "$REMOTE_NATIVE" "$CONCURRENT"
        echo
        echo "Remote Ktor samples: $REMOTE_KTOR_SAMPLES"
        echo
        if [ -n "$SAMPLE_HANG_BODY" ]; then
            echo "## Sample hang body"
            echo
            echo '```'
            printf '%s\n' "$SAMPLE_HANG_BODY"
            echo '```'
            echo
        fi
    } > "$REPORT_FILE"

    step "report written"
    echo "$REPORT_FILE"
    echo
    cat "$REPORT_FILE"

    # Exit code: pass if Ktor hung on both envs and native clean on both.
    if [ "${LOCAL_KTOR:-0}" -gt 0 ] && [ "${REMOTE_NATIVE:-1}" -eq 0 ] && [ "${LOCAL_NATIVE:-1}" -eq 0 ]; then
        # at least one remote-ktor sample saw a hang
        if awk -F'\t' '$1 ~ /^remote-ktor-/ { if ($3 > 0) found=1 } END { exit found ? 0 : 1 }' "$SUITE_RESULTS"; then
            exit 0
        fi
    fi
    exit 1
fi

############################################################################
# Single-mode path (existing behavior).
############################################################################
if [ "$NATIVE" -eq 1 ]; then
    TEST_PATH="/native"
    MODE="native fetch (no Ktor)"
else
    TEST_PATH="/"
    MODE="Ktor HttpClient"
fi
if [ "$REMOTE" -eq 1 ]; then
    URL="${REMOTE_URL}${TEST_PATH}"
    MODE="${MODE} [remote]"
else
    URL="http://localhost:${PORT}${TEST_PATH}"
fi

if [ "$REMOTE" -eq 1 ]; then
    step "remote target ${REMOTE_URL}"
    echo "skipping wrangler dev; hitting deployed worker directly"
else
    step "boot wrangler dev on :${PORT}"
    boot_wrangler
fi

echo "mode: ${MODE} (URL ${URL})"

if [ "$SEQUENTIAL" -gt 0 ]; then
    step "sequential x${SEQUENTIAL}"
    run_sequential "$URL" "$SEQUENTIAL" "seq" | tail -1 | \
        awk -F'\t' '{ printf "sequential summary: hangs=%d ok=%d other=%d\n", $2, $3, $4 }'
fi

step "concurrent burst x${CONCURRENT}"
SUMMARY=$(run_burst "$URL" "$CONCURRENT" "burst")
HANGS=$(echo "$SUMMARY" | cut -f3)
OK=$(echo "$SUMMARY" | cut -f4)
EXC=$(echo "$SUMMARY" | cut -f5)
EMPTY=$(echo "$SUMMARY" | cut -f6)

step "burst summary"
print_burst_table "burst"
printf '\n  hangs=%d  ok=%d  exception=%d  empty=%d  total=%d\n' \
    "$HANGS" "$OK" "$EXC" "$EMPTY" "$CONCURRENT"

HANG_BODY=$(grep -l "canceled this request\|error code: 1101" "$WORK_DIR/burst"/burst_*.body 2>/dev/null | head -1 || true)
if [ -n "$HANG_BODY" ]; then
    step "sample hang body ($(basename "$HANG_BODY"))"
    head -c 600 "$HANG_BODY"
    echo
fi

echo
if [ "$NATIVE" -eq 1 ]; then
    if [ "$HANGS" -eq 0 ]; then
        echo "RESULT: native fetch baseline clean (${OK}/${CONCURRENT} ok)."
        exit 0
    else
        echo "RESULT: native fetch hung (${HANGS}/${CONCURRENT}). Unexpected regression."
        exit 1
    fi
else
    if [ "$HANGS" -gt 0 ]; then
        echo "RESULT: bug reproduced on Ktor path (${HANGS}/${CONCURRENT} hangs)."
        exit 0
    else
        echo "RESULT: no hangs observed (${OK}/${CONCURRENT} ok)."
        echo "If you expected the bug to reproduce: rebuild without --skip-build,"
        echo "then re-run. The hang requires concurrent load against the Ktor path."
        exit 1
    fi
fi
