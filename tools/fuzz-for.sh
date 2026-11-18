#!/bin/sh
# Fuzzes in rounds until a deadline. Each round is `zig build test --fuzz`,
# which starts from what the rounds before it found, and no round starts that
# the last one says would not end by the deadline.
#
#   tools/fuzz-for.sh <minutes> [<runs of each fuzz test per round>]
#
# A failing input stops the rounds, and is saved in the Zig cache as f/crash.
set -eu

usage="usage: tools/fuzz-for.sh <minutes> [<runs of each fuzz test per round, such as 100K>]"
minutes=${1:-}
runs=${2:-100K}
case $minutes in
'' | *[!0-9]*)
  echo "$usage" >&2
  exit 2
  ;;
esac

began=$(date +%s)
end=$((began + minutes * 60))
last=0
round=0
while [ $(($(date +%s) + last)) -lt "$end" ]; do
  round=$((round + 1))
  start=$(date +%s)
  echo "fuzz round $round: $runs runs of each fuzz test"
  zig build test --fuzz="$runs"
  last=$(($(date +%s) - start))
  echo "fuzz round $round took ${last}s"
done
echo "fuzzed in $round rounds for $((($(date +%s) - began) / 60)) minutes, and found nothing"
