#!/usr/bin/env bash
# End-to-end test of the Ktor-on-Cloudflare-Workers hang reproduction.
#
# Builds the worker, boots wrangler dev (local miniflare), runs a
# concurrent burst against it, counts how many responses contain the
# "Workers runtime canceled this request" hang body, prints a summary,
# tears wrangler down.
#
# Usage:
#   ./test-repro.sh                  # Ktor path with Logging plugin (worst rate)
#   ./test-repro.sh --no-logging     # Ktor path without the Logging plugin
#   ./test-repro.sh --native         # native fetch path (no Ktor, hang-free baseline)
#   ./test-repro.sh -n 60            # 60 concurrent requests
#   ./test-repro.sh -p 8788          # bind wrangler on a different port
#   ./test-repro.sh -s 10            # also run N sequential requests first
#   ./test-repro.sh --keep           # leave wrangler running on exit (for poking)
#   ./test-repro.sh --skip-build     # reuse the existing compileSync output
#
# Exit status:
#   0  burst saw at least one hang (bug reproduced — Ktor path)
#      or burst saw zero hangs when --native was passed (expected baseline)
#   1  burst saw zero hangs on the Ktor path (bug NOT reproduced, investigate)
#      or burst saw a hang when --native was passed (regression in native path)
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
NO_LOGGING=0
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--concurrent) CONCURRENT=$2; shift 2;;
        -s|--sequential) SEQUENTIAL=$2; shift 2;;
        -p|--port) PORT=$2; shift 2;;
        --keep) KEEP=1; shift;;
        --skip-build) SKIP_BUILD=1; shift;;
        --native) NATIVE=1; shift;;
        --no-logging) NO_LOGGING=1; shift;;
        -h|--help) sed -n '2,/^$/p' "$0"; exit 0;;
        *) echo "unknown arg: $1" >&2; exit 2;;
    esac
done

if [ "$NATIVE" -eq 1 ] && [ "$NO_LOGGING" -eq 1 ]; then
    echo "--native and --no-logging are mutually exclusive" >&2
    exit 2
fi

if [ "$NATIVE" -eq 1 ]; then
    TEST_PATH="/native"
    MODE="native fetch (no Ktor)"
elif [ "$NO_LOGGING" -eq 1 ]; then
    TEST_PATH="/no-logging"
    MODE="Ktor HttpClient (no Logging plugin)"
else
    TEST_PATH="/"
    MODE="Ktor HttpClient (with Logging plugin)"
fi
URL="http://localhost:${PORT}${TEST_PATH}"

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

cleanup() {
    if [ "$KEEP" -eq 1 ] && [ -n "${WRANGLER_PID}" ]; then
        echo
        echo "Leaving wrangler dev running on http://localhost:${PORT} (PID ${WRANGLER_PID})."
        echo "Log: $LOG_FILE"
        echo "Stop with: kill ${WRANGLER_PID}"
        return
    fi

    if [ -n "${WRANGLER_PID}" ]; then
        kill_tree "$WRANGLER_PID" TERM
        # Give the tree a moment to exit cleanly.
        for _ in 1 2 3 4 5; do
            if ! kill -0 "$WRANGLER_PID" 2>/dev/null; then break; fi
            sleep 0.2
        done
        kill_tree "$WRANGLER_PID" KILL
    fi

    kill_port_listeners "$PORT"
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'echo "interrupted"; exit 130' INT TERM

step() { printf '\n=== %s ===\n' "$*"; }

# ---- pre-flight ----
step "pre-flight"
command -v node >/dev/null  || { echo "node not on PATH"; exit 2; }
command -v npm >/dev/null   || { echo "npm not on PATH"; exit 2; }
command -v curl >/dev/null  || { echo "curl not on PATH"; exit 2; }
[ -f ./gradlew ] || { echo "./gradlew missing, wrong directory?"; exit 2; }

if [ ! -x ./node_modules/.bin/wrangler ]; then
    echo "wrangler not installed; running npm install"
    npm install --silent || { echo "npm install failed"; exit 2; }
fi
WRANGLER="./node_modules/.bin/wrangler"

# ---- build ----
if [ "$SKIP_BUILD" -eq 0 ]; then
    step "build :jsProductionExecutableCompileSync"
    ./gradlew jsProductionExecutableCompileSync --quiet || { echo "gradle build failed"; exit 2; }
fi

BUNDLE="build/compileSync/js/main/productionExecutable/kotlin/ktor-cf-worker-hang-repro.mjs"
[ -f "$BUNDLE" ] || { echo "bundle missing at $BUNDLE, rebuild?"; exit 2; }

# ---- launch wrangler dev ----
step "boot wrangler dev on :${PORT}"
"$WRANGLER" dev --local --port "$PORT" >"$LOG_FILE" 2>&1 &
WRANGLER_PID=$!

READY=0
for _ in $(seq 1 60); do
    if grep -q "Ready on" "$LOG_FILE" 2>/dev/null; then
        READY=1; break
    fi
    if ! kill -0 "$WRANGLER_PID" 2>/dev/null; then
        echo "wrangler dev exited before becoming ready. log tail:"
        tail -30 "$LOG_FILE"
        exit 2
    fi
    sleep 0.5
done
if [ "$READY" -ne 1 ]; then
    echo "wrangler dev did not become ready within 30s. log tail:"
    tail -30 "$LOG_FILE"
    exit 2
fi
echo "wrangler ready (pid $WRANGLER_PID, log $LOG_FILE)"

# ---- helpers ----
classify_body() {
    local body_file=$1
    if [ ! -s "$body_file" ]; then echo "empty"; return; fi
    if grep -q "canceled this request" "$body_file"; then echo "hang"; return; fi
    if grep -q "^EXC:" "$body_file"; then echo "exception"; return; fi
    echo "ok"
}

echo "mode: ${MODE} (URL ${URL})"

# ---- sequential warm-up (optional) ----
if [ "$SEQUENTIAL" -gt 0 ]; then
    step "sequential x${SEQUENTIAL}"
    SEQ_HANGS=0; SEQ_OK=0; SEQ_OTHER=0
    for i in $(seq 1 "$SEQUENTIAL"); do
        body="$WORK_DIR/seq_$i.body"
        http=$(curl -sS -m 15 -o "$body" -w '%{http_code}' "$URL")
        kind=$(classify_body "$body")
        case "$kind" in
            hang) SEQ_HANGS=$((SEQ_HANGS+1));;
            ok) SEQ_OK=$((SEQ_OK+1));;
            *) SEQ_OTHER=$((SEQ_OTHER+1));;
        esac
        printf '  %2d  http=%s  body=%s\n' "$i" "$http" "$kind"
    done
    printf 'sequential summary: hangs=%d ok=%d other=%d\n' \
        "$SEQ_HANGS" "$SEQ_OK" "$SEQ_OTHER"
fi

# ---- concurrent burst ----
step "concurrent burst x${CONCURRENT}"
RESULTS_FILE="$WORK_DIR/results.tsv"
: > "$RESULTS_FILE"

burst_one() {
    local i=$1
    local body="$WORK_DIR/burst_${i}.body"
    local out
    out=$(curl -sS -m 30 -o "$body" \
        -w '%{http_code}\t%{time_total}' \
        "$URL" 2>/dev/null)
    printf '%s\t%s\t%s\n' "$i" "$out" "$(classify_body "$body")" >> "$RESULTS_FILE"
}

BURST_PIDS=()
for i in $(seq 1 "$CONCURRENT"); do
    burst_one "$i" &
    BURST_PIDS+=($!)
done
# Wait only for the burst children. A bare `wait` would also block on
# the wrangler dev background job which runs forever.
for pid in "${BURST_PIDS[@]}"; do
    wait "$pid"
done

HANGS=0; OK=0; EXC=0; EMPTY=0
while IFS=$'\t' read -r i http time kind; do
    case "$kind" in
        hang)      HANGS=$((HANGS+1));;
        ok)        OK=$((OK+1));;
        exception) EXC=$((EXC+1));;
        empty)     EMPTY=$((EMPTY+1));;
    esac
done < "$RESULTS_FILE"

step "burst summary"
sort -n "$RESULTS_FILE" | awk -F'\t' '{ printf "  %3d  http=%s  time=%-8s  body=%s\n", $1, $2, $3, $4 }'
printf '\n  hangs=%d  ok=%d  exception=%d  empty=%d  total=%d\n' \
    "$HANGS" "$OK" "$EXC" "$EMPTY" "$CONCURRENT"

# ---- one captured hang body for evidence ----
HANG_BODY=$(grep -l "canceled this request" "$WORK_DIR"/burst_*.body 2>/dev/null | head -1 || true)
if [ -n "$HANG_BODY" ]; then
    step "sample hang body ($(basename "$HANG_BODY"))"
    head -c 600 "$HANG_BODY"
    echo
fi

# ---- exit status ----
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
        echo "If you expected the bug to reproduce: check that wrangler.json still has"
        echo "compatibility_flags: [\"no_handle_cross_request_promise_resolution\"], and"
        echo "rebuild without --skip-build. Note --no-logging exercises the base Ktor"
        echo "engine which hangs at a lower (but still nonzero) rate locally."
        exit 1
    fi
fi
