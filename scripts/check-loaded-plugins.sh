#!/bin/sh

set -eu

fail() {
  printf 'loaded plugins check: FAIL (%s)\n' "$1" >&2
  exit 1
}

for command_name in awk curl docker grep python3; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    fail "required command is missing: $command_name"
  fi
done

compose_project=${COMPOSE_PROJECT:-devportal-local}
portal_url=${DEVPORTAL_URL:-http://localhost:${DEVPORTAL_PORT:-7007}}
portal_url=${portal_url%/}
face_file=/opt/app-root/src/dynamic-plugins.veecode.yaml

if ! face_config=$(docker compose -p "$compose_project" exec -T devportal cat "$face_file" 2>/dev/null); then
  fail "could not read the product face from the running devportal service"
fi

face_count=$(printf '%s\n' "$face_config" | awk '$1 == "-" && $2 == "package:" { count++ } END { print count + 0 }')
case "$face_count" in
  ''|*[!0-9]*) fail "could not count product-face entries" ;;
esac
if [ "$face_count" -eq 0 ]; then
  fail "the product face declares no package entries"
fi

enabled_refs=$(printf '%s\n' "$face_config" | awk '
function finish_entry() {
  if (in_entry && disabled != "true") print package
}
$1 == "-" && $2 == "package:" {
  finish_entry()
  package = $3
  gsub(sprintf("%c", 34), "", package)
  gsub(sprintf("%c", 39), "", package)
  in_entry = 1
  disabled = "false"
  next
}
in_entry && $1 == "disabled:" {
  disabled = tolower($2)
  gsub(sprintf("%c", 34), "", disabled)
  gsub(sprintf("%c", 39), "", disabled)
}
END {
  finish_entry()
}')
enabled_count=$(printf '%s\n' "$enabled_refs" | awk 'NF { count++ } END { print count + 0 }')
case "$enabled_count" in
  ''|*[!0-9]*) fail "could not count enabled product-face entries" ;;
esac

if ! auth_response=$(curl --silent --show-error --fail --max-time 15 \
  -X POST "$portal_url/api/auth/guest/refresh" \
  -H 'Content-Type: application/json' \
  -d '{}'); then
  fail "could not get a guest token from the running portal"
fi

if ! access_token=$(printf '%s' "$auth_response" | python3 -c '
import json
import sys

try:
    response = json.load(sys.stdin)
    identity = response.get("backstageIdentity") or {}
    token = identity.get("token") if isinstance(identity, dict) else None
    token = token or response.get("token") or response.get("accessToken")
except (AttributeError, TypeError, ValueError):
    sys.exit(1)

if not isinstance(token, str) or not token:
    sys.exit(1)
print(token)
' 2>/dev/null); then
  fail "guest refresh did not return a usable token"
fi
unset auth_response

if ! loaded_response=$(printf 'header = "Authorization: Bearer %s"\n' "$access_token" |
  curl --config - --silent --show-error --fail --max-time 30 \
    "$portal_url/api/dynamic-plugins-info/loaded-plugins"); then
  fail "could not read loaded plugins from the authenticated portal API"
fi
unset access_token

if ! loaded_count=$(printf '%s' "$loaded_response" | python3 -c '
import json
import sys

try:
    plugins = json.load(sys.stdin)
except (TypeError, ValueError):
    sys.exit(1)

if not isinstance(plugins, list):
    sys.exit(1)
print(len(plugins))
' 2>/dev/null); then
  fail "loaded-plugins API did not return a JSON array"
fi
case "$loaded_count" in
  ''|*[!0-9]*) fail "could not count loaded plugin records" ;;
esac

if ! match_report=$(printf '%s' "$loaded_response" | python3 -c '
import json
import sys

def expected_name(reference):
    if reference.startswith("oci://"):
        package = reference.rsplit("!", 1)[-1]
        package = package.rsplit("/", 1)[-1]
        if package.startswith("veecode-platform-"):
            return "@veecode-platform/" + package[len("veecode-platform-"):] + "-dynamic"
        return package + "-dynamic"
    if reference.startswith("./"):
        return reference.rsplit("/", 1)[-1]
    return reference

try:
    plugins = json.load(sys.stdin)
except (TypeError, ValueError):
    sys.exit(1)

if not isinstance(plugins, list):
    sys.exit(1)

loaded_names = {
    plugin["name"]
    for plugin in plugins
    if isinstance(plugin, dict) and isinstance(plugin.get("name"), str)
}
references = [reference for reference in sys.argv[1].splitlines() if reference]
expected_names = [expected_name(reference) for reference in references]
missing_names = [name for name in expected_names if name not in loaded_names]
print(str(len(expected_names) - len(missing_names)) + "|" + ",".join(missing_names))
' "$enabled_refs" 2>/dev/null); then
  fail "could not match enabled product-face entries to loaded plugin names"
fi
unset loaded_response
matching_count=${match_report%%|*}
missing_names=${match_report#*|}
case "$matching_count" in
  ''|*[!0-9]*) fail "could not count matching product-face plugins" ;;
esac

if ! installer_logs=$(docker compose -p "$compose_project" logs --no-color install-dynamic-plugins 2>/dev/null); then
  fail "could not read install-dynamic-plugins logs"
fi

printf 'loaded plugins check: product-face entries: %s (enabled: %s, disabled: %s)\n' \
  "$face_count" "$enabled_count" "$((face_count - enabled_count))"
printf 'loaded plugins check: API plugin records: %s\n' "$loaded_count"
printf 'loaded plugins check: enabled face entries found in API: %s of %s\n' \
  "$matching_count" "$enabled_count"

failed=0
if [ "$loaded_count" -lt "$enabled_count" ]; then
  printf 'loaded plugins check: FAIL (API reports %s plugins; product face enables %s)\n' "$loaded_count" "$enabled_count" >&2
  failed=1
fi
if [ "$matching_count" -lt "$enabled_count" ]; then
  printf 'loaded plugins check: FAIL (enabled product-face plugins missing from API: %s)\n' "$missing_names" >&2
  failed=1
fi

if printf '%s\n' "$installer_logs" | grep -Fqi 'Cannot find module'; then
  printf "loaded plugins check: FAIL (installer logs contain 'Cannot find module')\n" >&2
  failed=1
fi
if printf '%s\n' "$installer_logs" | grep -Eiq 'already registered'; then
  printf "loaded plugins check: FAIL (installer logs contain 'already registered')\n" >&2
  failed=1
fi
if printf '%s\n' "$installer_logs" | awk '
{
  line = tolower($0)
  if (line ~ /warn/ && line ~ /skip/ && (line ~ /entry/ || line ~ /package/)) {
    found = 1
  }
}
END { exit !found }'; then
  printf 'loaded plugins check: FAIL (installer logs contain a warning about a skipped entry)\n' >&2
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi

printf 'loaded plugins check: PASS\n'
