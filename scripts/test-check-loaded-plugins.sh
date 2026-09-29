#!/bin/sh
# check-loaded-plugins.sh reads the product face and the installer logs through
# FACE_CMD and LOGS_CMD, and the portal over HTTP. This runs it against fixture
# files and a stub portal API, and once against a stub docker for the defaults.
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
DATA_DIR=$ROOT_DIR/scripts/testdata/check-loaded-plugins
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-check-loaded-plugins.XXXXXX")
SERVER_PID=
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'loaded plugins check test: FAIL (%s)\n' "$1" >&2
  exit 1
}

cat > "$WORK_DIR/stub-api.py" <<'PY'
import http.server
import sys

TOKEN = "stub-token"
LOADED_FILE = sys.argv[2]


class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self, status, body):
        payload = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        if self.path == "/api/auth/guest/refresh":
            self.reply(200, '{"backstageIdentity": {"token": "%s"}}' % TOKEN)
        else:
            self.reply(404, "{}")

    def do_GET(self):
        if self.path != "/api/dynamic-plugins-info/loaded-plugins":
            self.reply(404, "{}")
        elif self.headers.get("Authorization") != "Bearer " + TOKEN:
            self.reply(401, "{}")
        else:
            with open(LOADED_FILE) as loaded:
                self.reply(200, loaded.read())

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w") as port_file:
    port_file.write(str(server.server_address[1]))
server.serve_forever()
PY

python3 "$WORK_DIR/stub-api.py" "$WORK_DIR/port" "$WORK_DIR/loaded.json" &
SERVER_PID=$!
tries=0
while [ ! -s "$WORK_DIR/port" ]; do
  tries=$((tries + 1))
  [ "$tries" -le 50 ] || fail "the stub API did not start"
  sleep 0.1
done
DEVPORTAL_URL="http://127.0.0.1:$(cat "$WORK_DIR/port")"
export DEVPORTAL_URL

# A docker that records its arguments and serves the fixtures, so the test can
# tell whether the script called it and with which arguments.
mkdir "$WORK_DIR/bin"
cat > "$WORK_DIR/bin/docker" <<EOS
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK_DIR/docker-calls"
case "\$*" in
  *' exec '*) cat "$DATA_DIR/face.yaml" ;;
  *' logs '*) cat "$DATA_DIR/installer-logs.txt" ;;
esac
EOS
chmod +x "$WORK_DIR/bin/docker"
PATH="$WORK_DIR/bin:$PATH"

FACE_FIXTURE=$DATA_DIR/face.yaml
LOGS_FIXTURE=$WORK_DIR/installer.log
export FACE_FIXTURE LOGS_FIXTURE
export FACE_CMD="cat \"\$FACE_FIXTURE\""
export LOGS_CMD="cat \"\$LOGS_FIXTURE\""

# Runs the script and sets status, out (stdout) and err (stderr).
run_check() {
  : > "$WORK_DIR/docker-calls"
  status=0
  sh "$ROOT_DIR/scripts/check-loaded-plugins.sh" > "$WORK_DIR/out" 2> "$WORK_DIR/err" || status=$?
  out=$(cat "$WORK_DIR/out")
  err=$(cat "$WORK_DIR/err")
}

expect_status() {
  [ "$status" -eq "$2" ] || fail "$1: exit status $status, expected $2 (stderr: $err)"
}

expect_line() {
  printf '%s\n' "$3" | grep -Fqx "$2" || fail "$1: missing line '$2' in: $3"
}

cp "$DATA_DIR/loaded-plugins.json" "$WORK_DIR/loaded.json"
cp "$DATA_DIR/installer-logs.txt" "$WORK_DIR/installer.log"

run_check
expect_status 'all plugins loaded' 0
expected='loaded plugins check: product-face entries: 4 (enabled: 3, disabled: 1)
loaded plugins check: API plugin records: 4
loaded plugins check: enabled face entries found in API: 3 of 3
loaded plugins check: PASS'
[ "$out" = "$expected" ] || fail "all plugins loaded: unexpected output: $out"
[ -z "$err" ] || fail "all plugins loaded: unexpected stderr: $err"
[ ! -s "$WORK_DIR/docker-calls" ] || fail "all plugins loaded: docker ran although FACE_CMD and LOGS_CMD are set"
printf 'loaded plugins check test: all plugins loaded: PASS\n'

sed 's/plugin-beta-dynamic/plugin-beta-renamed/' "$DATA_DIR/loaded-plugins.json" > "$WORK_DIR/loaded.json"
run_check
expect_status 'plugin missing from the API' 1
expect_line 'plugin missing from the API' \
  'loaded plugins check: FAIL (enabled product-face plugins missing from API: backstage-community-plugin-beta-dynamic)' "$err"
printf 'loaded plugins check test: plugin missing from the API: FAIL as expected\n'

cp "$DATA_DIR/loaded-plugins.json" "$WORK_DIR/loaded.json"
{
  cat "$DATA_DIR/installer-logs.txt"
  printf "Error: Cannot find module '@example/missing'\n"
} > "$WORK_DIR/installer.log"
run_check
expect_status 'Cannot find module in the installer logs' 1
expect_line 'Cannot find module in the installer logs' \
  "loaded plugins check: FAIL (installer logs contain 'Cannot find module')" "$err"
printf 'loaded plugins check test: Cannot find module in the installer logs: FAIL as expected\n'

unset FACE_CMD LOGS_CMD
export COMPOSE_PROJECT=test-project
run_check
expect_status 'docker compose defaults' 0
expect_line 'docker compose defaults' 'loaded plugins check: PASS' "$out"
calls=$(cat "$WORK_DIR/docker-calls")
[ "$calls" = 'compose -p test-project exec -T devportal cat /opt/app-root/src/dynamic-plugins.veecode.yaml
compose -p test-project logs --no-color install-dynamic-plugins' ] \
  || fail "docker compose defaults: unexpected docker calls: $calls"
printf 'loaded plugins check test: docker compose defaults: PASS\n'

printf 'loaded plugins check test: PASS (4 cases)\n'
