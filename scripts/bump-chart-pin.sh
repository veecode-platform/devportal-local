#!/bin/sh
# Move .chart-pin to the newest devportal-chart release and realign the image
# digest and the catalog index reference the composes default to.
#
# The pin is the contract: check-config-drift.sh clones the chart at .chart-pin
# and compares the derived config against it, so the pin and the derived
# references must move together. Prints "changed" on stdout when it wrote
# something, "unchanged" otherwise; always exits 0 unless it could not determine
# the answer.
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CHART_REPOSITORY=${CHART_REPOSITORY:-https://github.com/veecode-platform/devportal-chart.git}
PIN_FILE=$ROOT_DIR/.chart-pin
COMPOSE_FILES="docker-compose.yml docker-compose.dynamic-plugins-root.yml docker-compose.rbac-lab.yml"
INDEX_FILE=$ROOT_DIR/docker-compose.yml

fail() {
  printf 'chart bump: FAIL (%s)\n' "$1" >&2
  exit 1
}

# Prints one field (registry, repository or tag) of global.catalogIndex.image from
# a chart's values.yaml. The chart indents these keys two spaces per level, so each
# is matched at its exact depth; an unexpected layout prints nothing, and the caller
# fails rather than reading the wrong block.
index_field() {
  awk -v field="$1" '
    /^global:/ { g = 1; next }
    /^[^ #]/ { g = 0; c = 0; i = 0 }
    g && /^  catalogIndex:/ { c = 1; next }
    g && /^  [^ #]/ { c = 0; i = 0 }
    c && /^    image:/ { i = 1; next }
    c && /^    [^ #]/ { i = 0 }
    i && index($0, "      " field ":") == 1 {
      value = substr($0, length(field) + 8)
      sub(/^[ \t]+/, "", value)
      gsub(/"/, "", value)
      sub(/[ \t]*#.*/, "", value)
      sub(/[ \t]+$/, "", value)
      print value
      exit
    }
  ' "$2"
}

[ -f "$PIN_FILE" ] || fail "missing .chart-pin"
CURRENT_PIN=$(tr -d ' \t\n\r' < "$PIN_FILE")
[ -n "$CURRENT_PIN" ] || fail ".chart-pin is empty"

# Newest final chart-v* tag, by version order. ls-remote avoids cloning the chart just
# to read a tag name.
LATEST_PIN=$(git ls-remote --tags --refs "$CHART_REPOSITORY" 'chart-v*' 2>/dev/null \
  | awk -F/ '{print $NF}' \
  | grep -E '^chart-v[0-9]+\.[0-9]+\.[0-9]+$' \
  | sort -V \
  | tail -1)
[ -n "$LATEST_PIN" ] || fail "could not list chart-v* tags from $CHART_REPOSITORY"

if [ "$LATEST_PIN" = "$CURRENT_PIN" ]; then
  printf 'chart bump: already on %s\n' "$CURRENT_PIN" >&2
  printf 'unchanged\n'
  exit 0
fi

TMP_DIR=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$TMP_DIR'" EXIT INT TERM

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$LATEST_PIN" \
  --single-branch "$CHART_REPOSITORY" "$TMP_DIR/devportal-chart" \
  || fail "could not clone $CHART_REPOSITORY at $LATEST_PIN"

VALUES=$TMP_DIR/devportal-chart/charts/backstage/values.yaml
[ -f "$VALUES" ] || fail "chart $LATEST_PIN has no charts/backstage/values.yaml"

# The portal image digest lives under upstream.backstage.image. Take the first
# `digest: sha256:...` that follows the `repository: veecode/devportal` line so a
# sibling image (catalog-index, postgres) cannot be picked up by mistake.
NEW_DIGEST=$(awk '
  /repository:[[:space:]]*veecode\/devportal[[:space:]]*$/ { seen = 1 }
  seen && /digest:[[:space:]]*sha256:/ {
    sub(/.*digest:[[:space:]]*/, "")
    print
    exit
  }
' "$VALUES" | tr -d ' \t\r')

case "$NEW_DIGEST" in
  sha256:*) : ;;
  *) fail "no veecode/devportal digest found in chart $LATEST_PIN" ;;
esac

# Composed the way the chart composes CATALOG_INDEX_IMAGE, so a tag (repository
# veecode/plugin-catalog-index) and a digest (repository veecode/plugin-catalog-index@sha256,
# tag <hex>) both come out as a valid reference.
NEW_INDEX=$(index_field registry "$VALUES")/$(index_field repository "$VALUES"):$(index_field tag "$VALUES")
printf '%s\n' "$NEW_INDEX" \
  | grep -Eq '^[a-z0-9.:-]+/[a-z0-9._/-]+(@sha256:[0-9a-f]{64}|:[A-Za-z0-9_.-]+)$' \
  || fail "chart $LATEST_PIN has no usable global.catalogIndex.image (got '$NEW_INDEX')"

CURRENT_DIGEST=$(grep -ohE 'veecode/devportal@sha256:[0-9a-f]+' "$ROOT_DIR"/docker-compose.yml 2>/dev/null \
  | head -1 | sed 's/.*@//')
CURRENT_INDEX=$(awk '/^[[:space:]]*CATALOG_INDEX_IMAGE:/ { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }' "$INDEX_FILE")
[ -n "$CURRENT_INDEX" ] || fail "docker-compose.yml has no CATALOG_INDEX_IMAGE line"

# The composes are rewritten before the pin. A run that stops in between leaves the
# old pin behind, so the next run sees a change again and redoes the same edits.
for f in $COMPOSE_FILES; do
  [ -f "$ROOT_DIR/$f" ] || continue
  sed -i.bak -E \
    -e "s#(veecode/devportal@)sha256:[0-9a-f]+#\1${NEW_DIGEST}#g" \
    -e "s#^([[:space:]]*CATALOG_INDEX_IMAGE:[[:space:]]*).*#\1${NEW_INDEX}#" \
    "$ROOT_DIR/$f"
  rm -f "$ROOT_DIR/$f.bak"
done

printf '%s\n' "$LATEST_PIN" > "$PIN_FILE"

printf 'chart bump: %s -> %s\n' "$CURRENT_PIN" "$LATEST_PIN" >&2
printf 'chart bump: digest %s -> %s\n' "${CURRENT_DIGEST:-none}" "$NEW_DIGEST" >&2
printf 'chart bump: catalog index %s -> %s\n' "$CURRENT_INDEX" "$NEW_INDEX" >&2

# Consumed by the workflow to build the pull request body.
{
  printf 'previous_pin=%s\n' "$CURRENT_PIN"
  printf 'new_pin=%s\n' "$LATEST_PIN"
  printf 'previous_digest=%s\n' "${CURRENT_DIGEST:-none}"
  printf 'new_digest=%s\n' "$NEW_DIGEST"
  printf 'previous_index=%s\n' "$CURRENT_INDEX"
  printf 'new_index=%s\n' "$NEW_INDEX"
} > "$ROOT_DIR/.chart-bump-summary"

printf 'changed\n'
