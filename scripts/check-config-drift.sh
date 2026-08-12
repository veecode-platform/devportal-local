#!/bin/sh

set -eu

ROOT_DIR=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
CHART_REPOSITORY=https://github.com/veecode-platform/devportal-chart.git
PIN_FILE=$ROOT_DIR/.chart-pin
EXPECTED_FILES='app-config.veecode-auth.yaml app-config.veecode-branding.yaml app-config.extensions.yaml'
# Fragments the chart stores as Helm TEMPLATES, which we vendor RENDERED. A byte
# comparison is impossible by construction (the chart file contains `{{ }}`), so
# these are checked for existence on both sides instead: the local render must be
# present, and its template must still exist upstream at the pinned tag. If the
# template disappears or moves, this still fails loudly.
RENDERED_FILES='app-config.veecode-product.yaml'

if [ ! -f "$PIN_FILE" ]; then
  printf '%s\n' "config drift check: FAIL (missing .chart-pin)" >&2
  exit 1
fi

PIN=$(sed -n '1p' "$PIN_FILE")
if [ -z "$PIN" ]; then
  printf '%s\n' "config drift check: FAIL (.chart-pin is empty)" >&2
  exit 1
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/devportal-chart-drift.XXXXXX")
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

if ! git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$PIN" --single-branch "$CHART_REPOSITORY" "$TMP_DIR/devportal-chart"; then
  printf '%s\n' "config drift check: FAIL (could not clone $CHART_REPOSITORY at $PIN)" >&2
  exit 1
fi

FAILED=0
for NAME in $EXPECTED_FILES; do
  LOCAL_FILE=$ROOT_DIR/config/$NAME
  CHART_FILE=$TMP_DIR/devportal-chart/charts/backstage/files/veecode/$NAME

  if [ ! -f "$LOCAL_FILE" ]; then
    printf 'config drift: missing local file %s\n' "config/$NAME" >&2
    FAILED=1
    continue
  fi
  if [ ! -f "$CHART_FILE" ]; then
    printf 'config drift: missing pinned chart file %s\n' "charts/backstage/files/veecode/$NAME" >&2
    FAILED=1
    continue
  fi
  if ! cmp -s "$LOCAL_FILE" "$CHART_FILE"; then
    printf 'config drift: content differs for %s\n' "config/$NAME" >&2
    FAILED=1
  fi
done

for LOCAL_FILE in "$ROOT_DIR"/config/*; do
  [ -e "$LOCAL_FILE" ] || continue
  NAME=$(basename "$LOCAL_FILE")
  [ "$NAME" = README.md ] && continue
  case " $EXPECTED_FILES $RENDERED_FILES " in
    *" $NAME "*) ;;
    *)
      printf 'config drift: unexpected local file config/%s\n' "$NAME" >&2
      FAILED=1
      ;;
  esac
done

for NAME in $RENDERED_FILES; do
  LOCAL_FILE=$ROOT_DIR/config/$NAME
  CHART_FILE=$TMP_DIR/devportal-chart/charts/backstage/files/veecode/$NAME

  if [ ! -f "$LOCAL_FILE" ]; then
    printf 'config drift: missing local render config/%s\n' "$NAME" >&2
    FAILED=1
    continue
  fi
  if [ ! -f "$CHART_FILE" ]; then
    printf 'config drift: missing pinned chart template %s\n' "charts/backstage/files/veecode/$NAME" >&2
    FAILED=1
  fi
done

if [ "$FAILED" -ne 0 ]; then
  printf 'config drift check: FAIL (devportal-chart@%s)\n' "$PIN" >&2
  exit 1
fi

printf 'config drift check: PASS (3 fragments byte-match, 1 rendered fragment present; devportal-chart@%s)\n' "$PIN"
