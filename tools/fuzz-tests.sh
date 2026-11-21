#!/bin/sh
# Prints the name of every fuzz test, one per line, for the Fuzz workflow to
# give each a job of its own. A fuzz test is one whose name starts with
# "fuzz: ". A call of std.testing.fuzz in a test named otherwise is an error,
# since that test would get no job.
set -eu

cd "$(dirname "$0")/.."
names=$(sed -n 's/^test "\(fuzz: [^"]*\)" {$/\1/p' src/*.zig)
count=$(printf '%s\n' "$names" | awk 'NF { n++ } END { print n + 0 }')
calls=$(cat src/*.zig | awk '/testing\.fuzz\(/ { n++ } END { print n + 0 }')
if [ "$count" -ne "$calls" ]; then
  echo "src/ calls std.testing.fuzz $calls times, in $count tests named \"fuzz: ...\";" \
    "name every fuzz test \"fuzz: ...\", and give each one call" >&2
  exit 1
fi
printf '%s\n' "$names"
