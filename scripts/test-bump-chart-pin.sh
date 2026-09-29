#!/bin/sh
# bump-chart-pin.sh rewrites .chart-pin and the composes of the tree it sits in,
# so this runs a copy of it in a scratch tree against a local chart repository.
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-bump-chart-pin.XXXXXX")
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

TREE=$WORK_DIR/tree
CHART_SRC=$WORK_DIR/chart-src
CHART_BARE=$WORK_DIR/chart.git
export CHART_REPOSITORY="file://$CHART_BARE"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

fail() {
  printf 'chart bump test: FAIL (%s)\n' "$1" >&2
  exit 1
}

digest() {
  printf 'sha256:%s' "$(printf '%064d' 0 | tr 0 "$1")"
}

compose_digests() {
  grep -ohE 'veecode/devportal@sha256:[0-9a-f]+' "$TREE/docker-compose.yml" \
    | sed 's/.*@//' | sort -u
}

tag_chart() {
  cat > "$CHART_SRC/charts/backstage/values.yaml" <<EOF
upstream:
  backstage:
    image:
      repository: veecode/devportal
      digest: $(digest "$2")
EOF
  git -C "$CHART_SRC" add charts/backstage/values.yaml
  git -C "$CHART_SRC" commit -q -m "$1"
  git -C "$CHART_SRC" tag -a -m "$1" "$1"
  git -C "$CHART_SRC" push -q "$CHART_BARE" HEAD:refs/heads/main "refs/tags/$1"
}

check() {
  result=$(sh "$TREE/scripts/bump-chart-pin.sh") || fail "$1: bump-chart-pin.sh exited $?"
  pin=$(cat "$TREE/.chart-pin")
  [ "$result" = "$2" ] || fail "$1: printed '$result', expected '$2'"
  [ "$pin" = "$3" ] || fail "$1: pin is $pin, expected $3"
  digests=$(compose_digests)
  [ "$digests" = "$4" ] || fail "$1: compose digest is '$digests', expected '$4'"
  printf 'chart bump test: %s: %s, pin %s\n' "$1" "$result" "$pin"
}

mkdir -p "$TREE/scripts" "$CHART_SRC/charts/backstage"
cp "$ROOT_DIR/scripts/bump-chart-pin.sh" "$TREE/scripts/"
cp "$ROOT_DIR/docker-compose.yml" "$TREE/"
printf 'chart-v0.1.25\n' > "$TREE/.chart-pin"
OLD_DIGEST=$(compose_digests)
git init -q --bare "$CHART_BARE"
git init -q "$CHART_SRC"

tag_chart chart-v0.1.25 a
check 'only chart-v0.1.25' unchanged chart-v0.1.25 "$OLD_DIGEST"

tag_chart chart-v1.0.0-rc.1 b
tag_chart chart-v1.0.0-rc.2 c
check 'chart-v1.0.0-rc.1 and chart-v1.0.0-rc.2 added' unchanged chart-v0.1.25 "$OLD_DIGEST"

tag_chart chart-v1.0.0 d
check 'chart-v1.0.0 added' changed chart-v1.0.0 "$(digest d)"
grep -qx 'new_pin=chart-v1.0.0' "$TREE/.chart-bump-summary" \
  || fail "chart-v1.0.0 added: .chart-bump-summary does not say new_pin=chart-v1.0.0"

printf 'chart bump test: PASS (3 cases)\n'
