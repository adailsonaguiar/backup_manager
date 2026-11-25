#!/usr/bin/env bash
# Tests the backup flow with local stubs; no database, AWS account or Docker needed.
set -Eeuo pipefail

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/run/backup" "$tmp/run/secrets" "$tmp/backups" "$tmp/bin"

sed \
  -e "s@/run/backup@$tmp/run/backup@g" \
  -e "s@/run/secrets@$tmp/run/secrets@g" \
  -e "s@/var/backups/postgresql@$tmp/backups@g" \
  scripts/backup.sh > "$tmp/backup.sh"

cat > "$tmp/run/backup/config" <<'EOF'
export PGDATABASE=testdb
export S3_BUCKET=test-bucket
export BACKUP_NAME=senha_antiga
export AWS_REGION=sa-east-1
EOF
printf 'http://kuma.internal/api/push/token\n' > "$tmp/run/secrets/kuma_push_url"

cat > "$tmp/bin/pg_dump" <<'EOF'
#!/usr/bin/env bash
echo pg_dump >> "$MOCK_LOG"
[[ "${FAIL_DUMP:-}" != 1 ]] || exit 2
for arg in "$@"; do
  case "$arg" in --file=*) printf 'dump' > "${arg#--file=}";; esac
done
EOF
cat > "$tmp/bin/pg_restore" <<'EOF'
#!/usr/bin/env bash
echo pg_restore >> "$MOCK_LOG"
[[ "${FAIL_VERIFY:-}" != 1 ]]
EOF
cat > "$tmp/bin/aws" <<'EOF'
#!/usr/bin/env bash
echo aws >> "$MOCK_LOG"
for arg in "$@"; do
  case "$arg" in s3://*) printf '%s\n' "$arg" > "$MOCK_DEST";; esac
done
[[ "${FAIL_UPLOAD:-}" != 1 ]]
EOF
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo curl >> "$MOCK_LOG"
EOF
# macOS does not ship flock; this stub isolates the job flow from locking.
cat > "$tmp/bin/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp/bin/"*
export MOCK_LOG="$tmp/calls"
export MOCK_DEST="$tmp/destination"
export PATH="$tmp/bin:$PATH"

run_and_expect() {
  local expected_status=$1 expected_calls=$2
  : > "$MOCK_LOG"
  local status=0
  bash "$tmp/backup.sh" > "$tmp/output" 2>&1 || status=$?
  if (( status != expected_status )); then
    cat "$tmp/output" >&2
    printf 'Expected exit %s, got %s\n' "$expected_status" "$status" >&2
    exit 1
  fi
  [[ "$(paste -sd, "$MOCK_LOG")" == "$expected_calls" ]] || {
    cat "$MOCK_LOG" >&2
    printf 'Expected calls: %s\n' "$expected_calls" >&2
    exit 1
  }
  if [[ "$expected_calls" == *aws* ]]; then
    [[ "$(cat "$MOCK_DEST")" == s3://test-bucket/postgresql/testdb/backup-*.dump ]] || {
      printf 'Unexpected S3 destination: %s\n' "$(cat "$MOCK_DEST")" >&2
      exit 1
    }
  fi
  if find "$tmp/backups" -mindepth 1 -print -quit | grep -q .; then
    echo 'Temporary dump was not removed' >&2
    exit 1
  fi
}

run_and_expect 0 'pg_dump,pg_restore,aws,curl'
FAIL_DUMP=1 run_and_expect 2 'pg_dump'
FAIL_VERIFY=1 run_and_expect 1 'pg_dump,pg_restore'
FAIL_UPLOAD=1 run_and_expect 1 'pg_dump,pg_restore,aws'
echo 'Backup flow: OK'
