#!/bin/sh
# Fuzzes until a deadline, on every core. `zig build test --fuzz` without a
# limit runs a fuzzer on each core, and they pass each other the inputs they
# find. Each fuzz test starts from the inputs that earlier fuzzing saved in
# the Zig cache.
#
#   tools/fuzz-for.sh <minutes> [<test name>...]
#
# Test names choose the fuzz tests to fuzz, as -Dtest-filter does; without
# them, every fuzz test is fuzzed. FUZZ_SEED, if set, seeds the fuzzers, which
# add each core's number to it; otherwise the build picks a seed at random.
#
# Without a limit the build never ends by itself. A fuzz test that fails saves
# its input in the Zig cache as f/crash, and the build goes on serving its web
# UI. So this watches for that file, and for errors in the build's output, and
# stops the build at the first of them, with exit status 1, or at the
# deadline, with 0.
#
# The tests are built ReleaseSafe, which keeps every safety check. Debug
# builds for x86_64 use Zig's own backend, which does not instrument code for
# the fuzzer, and the fuzzer then fails for want of coverage.
set -eu

usage="usage: tools/fuzz-for.sh <minutes> [<test name>...]"
minutes=${1:-}
case $minutes in
'' | *[!0-9]*)
  echo "$usage" >&2
  exit 2
  ;;
esac
shift

cd "$(dirname "$0")/.."
cache=${ZIG_LOCAL_CACHE_DIR:-.zig-cache}
crash=$cache/f/crash
work=$(mktemp -d)
log=$work/build.log
pid=
trap 'if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi; rm -rf "$work"' EXIT
trap 'exit 130' INT TERM

# The test names become -Dtest-filter options, in their place.
n=$#
while [ "$n" -gt 0 ]; do
  set -- "$@" "-Dtest-filter=$1"
  shift
  n=$((n - 1))
done
if [ -n "${FUZZ_SEED:-}" ]; then
  set -- "$@" "--seed=$FUZZ_SEED"
fi

# The inputs the fuzzers have saved, of every fuzz test in the cache.
saved() {
  find "$cache/f" -mindepth 2 -type f ! -name readlock ! -name synclock 2>/dev/null |
    wc -l | tr -d ' '
}

# Whether the fuzz test that failed saved its input since the build started.
crashed() {
  [ -f "$crash" ] && [ -n "$(find "$crash" -newer "$work/started")" ]
}

# Whether the build has ended. A build that ended is a zombie until it is
# waited for, and a zombie still answers kill -0.
ended() {
  case $(ps -o stat= -p "$pid" 2>/dev/null) in
  '' | Z*) return 0 ;;
  *) return 1 ;;
  esac
}

began=$(date +%s)
end=$((began + minutes * 60))
report=$((began + 30 * 60))
echo "fuzzing for $minutes minutes${FUZZ_SEED:+ with seed $FUZZ_SEED}," \
  "starting from $(saved) saved inputs"
touch "$work/started"
zig build test -Doptimize=ReleaseSafe --fuzz "$@" >"$log" 2>&1 &
pid=$!
failed=
while :; do
  sleep 10
  now=$(date +%s)
  if crashed; then
    failed="a fuzz test failed"
  elif grep -q '^error: ' "$log"; then
    failed="the build failed"
  elif ended; then
    failed="the build stopped by itself"
  elif [ "$now" -ge "$end" ]; then
    break
  elif [ "$now" -ge "$report" ]; then
    echo "fuzzed for $(((now - began) / 60)) minutes; $(saved) inputs saved"
    report=$((report + 30 * 60))
  fi
  if [ -n "$failed" ]; then
    # The build reports a failure just after it saves the input.
    sleep 5
    break
  fi
done
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
pid=
cat "$log"
minutes_taken=$((($(date +%s) - began) / 60))
if [ -n "$failed" ]; then
  echo "$failed after $minutes_taken minutes" >&2
  if crashed; then
    echo "replay its input with: zig build test -Dfuzz-input=$crash" >&2
  fi
  exit 1
fi
echo "fuzzed for $minutes_taken minutes, and found nothing; $(saved) inputs saved"
