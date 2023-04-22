#!/bin/bash
set -e

# Defaults
HEALTHCHECK_TIMEOUT=60
NO_HEALTHCHECK_TIMEOUT=10

# Print metadata for Docker CLI plugin
if [[ "$1" == "docker-cli-plugin-metadata" ]]; then
  cat <<EOF
{
  "SchemaVersion": "0.1.0",
  "Vendor": "Karol Musur",
  "Version": "v0.2",
  "ShortDescription": "Rollout new Compose service version"
}
EOF
  exit
fi

# check if compose v2 is available
if docker compose > /dev/null 2>&1; then
  COMPOSE_COMMAND="docker compose"
elif docker-compose > /dev/null 2>&1; then
  COMPOSE_COMMAND="docker-compose"
else
  echo "docker compose or docker-compose is required"
  exit 1
fi

# Shift arguments to remove plugin name
[[ $1 == "rollout" ]] && shift

usage() {
  cat <<EOF
Usage: docker rollout [OPTIONS] SERVICE
Rollout new Compose service version.
Options:
  -h, --help        Print usage
  -f, --file FILE   Compose configuration files
  -t, --timeout N   Healthcheck timeout (default: $HEALTHCHECK_TIMEOUT seconds)
  -w, --wait N      When no healthcheck is defined, wait for N seconds before
                    stopping old container (default: $NO_HEALTHCHECK_TIMEOUT seconds)
EOF
}

exit_with_usage() {
  usage
  exit 1
}

healthcheck() {
  local container_id="$1"

  if docker inspect --format='{{json .State.Health.Status}}' "$container_id" | grep -q "healthy"; then
    return 0
  fi

  return 1
}

scale() {
  local service="$1"
  local replicas="$2"

  # COMPOSE_FILES must be unquoted to allow multiple files
  # shellcheck disable=SC2086
  $COMPOSE_COMMAND $COMPOSE_FILES up --detach --scale "$service=$replicas" --no-recreate "$service"
}

main() {
  # "--quiet" returns only container IDs
  # COMPOSE_FILES must be unquoted to allow multiple files
  # shellcheck disable=SC2086
  OLD_CONTAINER_ID=$($COMPOSE_COMMAND $COMPOSE_FILES ps --quiet "$SERVICE")

  if [[ "$OLD_CONTAINER_ID" == "" ]]; then
    echo "=> Service '$SERVICE' is not running. Starting the service."
    # COMPOSE_FILES must be unquoted to allow multiple files
    # shellcheck disable=SC2086
    $COMPOSE_COMMAND $COMPOSE_FILES up --detach "$SERVICE"
    exit 0
  fi

  if [[ $(echo "$OLD_CONTAINER_ID" | wc -l) -gt 1 ]]; then
    echo "Service '$SERVICE' has more than one container running. Make sure 'scale' is set to 1." >&2
    echo "Fix with: $COMPOSE_COMMAND up --detach --scale $SERVICE=1 $SERVICE" >&2
    exit 1
  fi

  echo "==> Scaling '$SERVICE' to 2 instances"
  scale "$SERVICE" 2

  # COMPOSE_FILES must be unquoted to allow multiple files
  # shellcheck disable=SC2086
  NEW_CONTAINER_ID=$($COMPOSE_COMMAND $COMPOSE_FILES ps --quiet "$SERVICE" | grep -v "$OLD_CONTAINER_ID")

  # check if container has healthcheck
  if docker inspect --format='{{json .State.Health}}' "$OLD_CONTAINER_ID" | grep -q "Status"; then
    echo "==> Waiting for new container to be healthy (timeout: $HEALTHCHECK_TIMEOUT seconds)"
    for _ in $(seq 1 "$HEALTHCHECK_TIMEOUT"); do
      # break if healthcheck is successful
      healthcheck "$NEW_CONTAINER_ID" && break
      sleep 1
    done

    # rollback if healthcheck is not successful after timeout
    if ! healthcheck "$NEW_CONTAINER_ID"; then
      echo "==> New container is not healthy. Rolling back." >&2
      docker stop "$NEW_CONTAINER_ID"
      docker rm "$NEW_CONTAINER_ID"
      exit 1
    fi
  else
    echo "==> Waiting for new container to be ready ($NO_HEALTHCHECK_TIMEOUT seconds)"
    sleep "$NO_HEALTHCHECK_TIMEOUT"
  fi

  echo "==> Stopping old container"
  docker stop "$OLD_CONTAINER_ID"
  docker rm "$OLD_CONTAINER_ID"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -f | --file)
      COMPOSE_FILES="$COMPOSE_FILES -f $2"
      shift 2
      ;;
    -t | --timeout)
      HEALTHCHECK_TIMEOUT="$2"
      shift 2
      ;;
    -w | --wait)
      NO_HEALTHCHECK_TIMEOUT="$2"
      shift 2
      ;;
    -*)
      echo "Unknown option: $1"
      exit_with_usage
      ;;
    *)
      if [[ -n "$SERVICE" ]]; then
        echo "SERVICE is already set to '$SERVICE'"
        exit_with_usage
      fi

      SERVICE="$1"
      shift
      ;;
  esac
done

# Require SERVICE argument
if [[ -z "$SERVICE" ]]; then
  echo "SERVICE is missing"
  exit_with_usage
fi

main
