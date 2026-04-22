#!/usr/bin/env bash
set -euo pipefail

# Idempotent server-side deploy script for Bluette Server.
# Handles first-time bootstrap (env/service/directories) and normal redeploys.
#
# Usage (Bentley-style):
#   sudo BRANCH=main ./ops/deploy.sh
#   sudo ./ops/deploy.sh

APP_DIR="${APP_DIR:-/opt/bluette_server}"
BRANCH="${BRANCH:-main}"
RELEASE_NAME="${RELEASE_NAME:-bluette_server}"
SERVICE_NAME="${SERVICE_NAME:-bluette}"
SERVICE_USER="${SERVICE_USER:-bluette}"
SERVICE_GROUP="${SERVICE_GROUP:-$SERVICE_USER}"
ENV_FILE="${ENV_FILE:-/etc/bluette/bluette.env}"
SERVICE_FILE="${SERVICE_FILE:-/etc/systemd/system/${SERVICE_NAME}.service}"
SERVICE_TEMPLATE="${SERVICE_TEMPLATE:-$APP_DIR/ops/bluette.service.example}"
ENV_TEMPLATE="${ENV_TEMPLATE:-$APP_DIR/ops/bluette.env.example}"
AUTO_STASH_DIRTY_REPO="${AUTO_STASH_DIRTY_REPO:-1}"

require_command() {
  cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd"
    exit 1
  fi
}

check_elixir_version() {
  version="$(elixir -e 'IO.puts(System.version())' 2>/dev/null)"
  major="$(echo "$version" | cut -d. -f1)"
  minor="$(echo "$version" | cut -d. -f2)"

  if [ -z "$major" ] || [ -z "$minor" ]; then
    echo "ERROR: unable to parse Elixir version from: $version"
    exit 1
  fi

  if [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 19 ]; }; then
    echo "ERROR: Elixir ~> 1.19 is required, found: $version"
    exit 1
  fi
}

preflight_checks() {
  echo "==> Running preflight checks"
  require_command git
  require_command mix
  require_command elixir
  require_command systemctl
  check_elixir_version
}

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

bootstrap_os_resources() {
  echo "==> Ensuring service user and directories"

  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    run_root useradd --system --no-create-home --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
  fi

  run_root mkdir -p "$APP_DIR" "$(dirname "$ENV_FILE")"
  run_root chown "$SERVICE_USER:$SERVICE_GROUP" "$APP_DIR"
  run_root chown "root:$SERVICE_GROUP" "$(dirname "$ENV_FILE")"
  run_root chmod 750 "$(dirname "$ENV_FILE")"
}

ensure_source_checkout_exists() {
  if [ -d "$APP_DIR/.git" ]; then
    return
  fi

  echo "ERROR: $APP_DIR is not a git repository"
  echo "Clone your project first, then re-run deploy."
  echo "Example:"
  echo "  git clone --branch $BRANCH <repo_url> $APP_DIR"
  exit 1
}

bootstrap_env_file() {
  if [ -f "$ENV_FILE" ]; then
    return
  fi

  echo "==> Creating missing env file from template"
  if [ ! -f "$ENV_TEMPLATE" ]; then
    echo "ERROR: env template not found: $ENV_TEMPLATE"
    exit 1
  fi

  run_root cp "$ENV_TEMPLATE" "$ENV_FILE"
  run_root chown root:root "$ENV_FILE"
  run_root chmod 600 "$ENV_FILE"

  echo "==> Created $ENV_FILE from template"
  echo "    Set FIREBASE_PROJECT_ID and re-run deploy"
  echo "    nano $ENV_FILE"
  exit 0
}

bootstrap_service_file() {
  if [ -f "$SERVICE_FILE" ]; then
    return
  fi

  echo "==> Installing missing systemd service unit"
  if [ ! -f "$SERVICE_TEMPLATE" ]; then
    echo "ERROR: service template not found: $SERVICE_TEMPLATE"
    exit 1
  fi

  run_root cp "$SERVICE_TEMPLATE" "$SERVICE_FILE"
  run_root systemctl daemon-reload
  run_root systemctl enable "$SERVICE_NAME"
}

ensure_service_file_unprivileged() {
  if [ ! -f "$SERVICE_FILE" ]; then
    return
  fi

  if run_root grep -Eq '^(AmbientCapabilities|CapabilityBoundingSet)=CAP_NET_BIND_SERVICE$' "$SERVICE_FILE"; then
    echo "==> Removing privileged bind capabilities from service unit"
    run_root sed -i '/^AmbientCapabilities=CAP_NET_BIND_SERVICE$/d' "$SERVICE_FILE"
    run_root sed -i '/^CapabilityBoundingSet=CAP_NET_BIND_SERVICE$/d' "$SERVICE_FILE"
    run_root systemctl daemon-reload
  fi
}

ensure_service_file_release_mode() {
  if [ ! -f "$SERVICE_FILE" ]; then
    return
  fi

  release_cmd="ExecStart=${APP_DIR}/_build/prod/rel/${RELEASE_NAME}/bin/${RELEASE_NAME} start"

  if run_root grep -q '^ExecStart=/usr/bin/env mix run --no-halt$' "$SERVICE_FILE"; then
    echo "==> Updating service unit to run release start"
    run_root sed -i "s#^ExecStart=/usr/bin/env mix run --no-halt$#${release_cmd}#" "$SERVICE_FILE"
    run_root systemctl daemon-reload
  fi

  if run_root grep -q "^ExecStart=.*/bin/${RELEASE_NAME} foreground$" "$SERVICE_FILE"; then
    echo "==> Updating service unit command: foreground -> start"
    run_root sed -i "s#^ExecStart=.*/bin/${RELEASE_NAME} foreground$#${release_cmd}#" "$SERVICE_FILE"
    run_root systemctl daemon-reload
  fi
}

validate_runtime_env() {
  echo "==> Loading runtime environment from $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a

  auth_verifier="${AUTH_VERIFIER:-firebase}"
  auth_verifier="$(printf '%s' "$auth_verifier" | tr '[:upper:]' '[:lower:]')"

  case "$auth_verifier" in
    firebase)
      if [ -z "${FIREBASE_PROJECT_ID:-}" ] || [ "${FIREBASE_PROJECT_ID}" = "replace-me" ]; then
        echo "ERROR: FIREBASE_PROJECT_ID must be set in $ENV_FILE when AUTH_VERIFIER=firebase"
        exit 1
      fi
      ;;
    mock)
      echo "==> AUTH_VERIFIER=mock (Firebase verification disabled)"
      ;;
    *)
      echo "ERROR: AUTH_VERIFIER must be 'firebase' or 'mock' (got: ${AUTH_VERIFIER:-})"
      exit 1
      ;;
  esac
}

ensure_db_directory() {
  DB_PATH="${DATABASE_PATH:-/var/lib/bluette_server/bluette_server.db}"

  if [[ "$DB_PATH" != /* ]]; then
    echo "ERROR: DATABASE_PATH must be an absolute path, got: $DB_PATH"
    exit 1
  fi

  DB_DIR="$(dirname "$DB_PATH")"
  echo "==> Ensuring database directory exists: $DB_DIR"
  run_root mkdir -p "$DB_DIR"
  run_root chown "$SERVICE_USER:$SERVICE_GROUP" "$DB_DIR"
  run_root chmod 750 "$DB_DIR"
}

update_source() {
  echo "==> Updating source from origin/$BRANCH"
  git config --global --add safe.directory "$APP_DIR"
  git -C "$APP_DIR" fetch origin "$BRANCH"
  git -C "$APP_DIR" checkout "$BRANCH"

  if [ -n "$(git -C "$APP_DIR" status --porcelain)" ]; then
    if [ "$AUTO_STASH_DIRTY_REPO" = "1" ]; then
      stash_name="deploy-auto-$(date +%s)"
      echo "==> Local git changes detected; stashing automatically ($stash_name)"
      git -C "$APP_DIR" stash push --include-untracked -m "$stash_name" >/dev/null
    else
      echo "ERROR: local git changes detected. Commit/stash or set AUTO_STASH_DIRTY_REPO=1"
      exit 1
    fi
  fi

  git -C "$APP_DIR" pull --ff-only origin "$BRANCH"
}

build_and_migrate() {
  echo "==> Building release and running migrations"
  bash -lc "cd '$APP_DIR'; export MIX_ENV=prod; mix local.hex --force; mix local.rebar --force; mix deps.get --only prod; mix compile; mix ecto.migrate; mix release --overwrite"
}

fix_sqlite_ownership() {
  DB_PATH="${DATABASE_PATH:-/var/lib/bluette_server/bluette_server.db}"

  if [ -f "$DB_PATH" ]; then
    echo "==> Fixing sqlite file ownership"
    run_root chown "$SERVICE_USER:$SERVICE_GROUP" "$DB_PATH"
    run_root chmod 640 "$DB_PATH"
  fi

  if [ -f "${DB_PATH}-wal" ]; then
    run_root chown "$SERVICE_USER:$SERVICE_GROUP" "${DB_PATH}-wal"
    run_root chmod 640 "${DB_PATH}-wal"
  fi

  if [ -f "${DB_PATH}-shm" ]; then
    run_root chown "$SERVICE_USER:$SERVICE_GROUP" "${DB_PATH}-shm"
    run_root chmod 640 "${DB_PATH}-shm"
  fi
}

restart_service() {
  echo "==> Restarting service: $SERVICE_NAME"
  run_root systemctl daemon-reload
  run_root systemctl enable "$SERVICE_NAME"
  run_root systemctl restart "$SERVICE_NAME"
  run_root systemctl status "$SERVICE_NAME" --no-pager
}

main() {
  preflight_checks
  bootstrap_os_resources
  ensure_source_checkout_exists
  bootstrap_env_file
  bootstrap_service_file
  ensure_service_file_unprivileged
  ensure_service_file_release_mode
  validate_runtime_env
  ensure_db_directory
  update_source
  build_and_migrate
  fix_sqlite_ownership
  restart_service

  echo "==> Done"
}

main
