#!/bin/sh
# Builds, runs and replays Coincide's fuzzers.
#
#   Fuzz/fuzz.sh replay [fuzzer] [file...]  Build with any toolchain and run the seed corpus (or the
#                                           given files, such as a crash artifact) through the checks.
#   Fuzz/fuzz.sh build [fuzzer]             Build with libFuzzer and AddressSanitizer.
#   Fuzz/fuzz.sh run <fuzzer> [seconds]     Fuzz for a bounded time (default 60). Crashes are saved in
#                                           .build/fuzz-artifacts.
#   Fuzz/fuzz.sh check                      Check the sources are in sync with CoincideKit and the workflow.
#   Fuzz/fuzz.sh list [--json]              Print the fuzzer names.
#
# libFuzzer ships with swift.org toolchains and the swift Docker images, not with Xcode. On a Mac,
# build and run use the toolchain named by SWIFT_TOOLCHAIN (default: the latest swift.org one).
set -eu
cd "$(dirname "$0")"

die() {
  echo "fuzz.sh: $*" >&2
  exit 2
}

fuzzers() {
  for dir in Sources/*Fuzzer; do basename "$dir"; done
}

known() {
  [ -d "Sources/$1" ] && [ "${1%Fuzzer}" != "$1" ] || die "no fuzzer named '$1' (see: fuzz.sh list)"
}

libfuzzer_swift() {
  if [ "$(uname)" = Darwin ]; then
    xcrun --toolchain "${SWIFT_TOOLCHAIN:-swift}" swift "$@"
  else
    swift "$@"
  fi
}

command="${1:-}"
[ $# -gt 0 ] && shift

case "$command" in
list)
  if [ "${1:-}" = --json ]; then
    printf '['
    separator=''
    for name in $(fuzzers); do
      printf '%s"%s"' "$separator" "$name"
      separator=','
    done
    printf ']\n'
  else
    fuzzers
  fi
  ;;

replay)
  if [ $# -gt 0 ]; then
    known "$1"
    name="$1"
    shift
    swift build --product "$name"
    ".build/debug/$name" "$@"
  else
    swift build
    status=0
    for name in $(fuzzers); do
      # Only the summary on success; everything (the failing input is the last file named) otherwise.
      if output="$(".build/debug/$name" 2>&1)"; then
        printf '%s\n' "$output" | tail -n 1
      else
        printf '%s\n' "$output"
        status=1
      fi
    done
    exit "$status"
  fi
  ;;

build)
  set -- ${1:+--product "$1"}
  libfuzzer_swift build -c release --sanitize=fuzzer --sanitize=address -Xswiftc -DCOINCIDE_FUZZING \
    --scratch-path .build/fuzz "$@"
  ;;

run)
  [ $# -ge 1 ] || die "usage: fuzz.sh run <fuzzer> [seconds]"
  known "$1"
  name="$1"
  seconds="${2:-60}"
  case "$seconds" in '' | *[!0-9]*) die "seconds must be a whole number, not '$seconds'" ;; esac
  [ "$seconds" -ge 1 ] && [ "$seconds" -le 3600 ] || die "seconds must be between 1 and 3600"
  binary=".build/fuzz/release/$name"
  [ -x "$binary" ] || die "build it first: fuzz.sh build $name"
  # New inputs go to a scratch corpus so the checked-in seeds stay small and reviewed.
  mkdir -p ".build/fuzz-corpus/$name" .build/fuzz-artifacts
  set -- -max_total_time="$seconds" -timeout=10 -rss_limit_mb=2048 -max_len=8192 -print_final_stats=1 \
    -artifact_prefix=".build/fuzz-artifacts/$name-"
  [ -f "Dictionaries/$name.dict" ] && set -- "$@" -dict="Dictionaries/$name.dict"
  # Leak checking is off: the code under test is value types, and LeakSanitizer reports Foundation's
  # own caches on Linux. AddressSanitizer still catches every memory error.
  set -- "$@" -detect_leaks=0
  "$binary" "$@" ".build/fuzz-corpus/$name" "Corpus/$name"
  ;;

check)
  status=0
  # The ChangedFile shim must match the definition in CoincideKit.
  extract() { awk '/^public struct ChangedFile/,/^}/' "$1"; }
  if [ "$(extract ../CoincideKit/Git/CheckpointService.swift)" != "$(extract Shims/ChangedFile.swift)" ]; then
    echo "Shims/ChangedFile.swift no longer matches ChangedFile in CoincideKit/Git/CheckpointService.swift." >&2
    echo "Copy the new definition, or delete the shim and its symlinks if ChangedFile moved to GitModels.swift." >&2
    status=1
  fi
  for name in $(fuzzers); do
    [ -n "$(ls "Corpus/$name" 2>/dev/null)" ] || {
      echo "$name has no seed corpus in Corpus/$name" >&2
      status=1
    }
    for link in "Sources/$name"/*.swift; do
      [ -L "$link" ] || continue
      if [ ! -e "$link" ]; then
        echo "$link points to a missing file" >&2
        status=1
        continue
      fi
      # Pull requests that change a fuzzed file must run the fuzzers.
      target="$(readlink "$link" | sed 's|^\(\.\./\)*||')"
      case "$target" in
      CoincideKit/*)
        grep -qF -- "- \"$target\"" ../.github/workflows/fuzz.yml || {
          echo "$target is fuzzed by $name but missing from the paths in .github/workflows/fuzz.yml" >&2
          status=1
        }
        ;;
      esac
    done
  done
  [ "$status" -eq 0 ] && echo "Fuzz sources are in sync."
  exit "$status"
  ;;

*)
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
  [ -z "$command" ] || exit 2
  ;;
esac
