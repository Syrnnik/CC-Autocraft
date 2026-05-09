set dotenv-load

default:
  just --list

check:
  stylua --check src
  luacheck src

deploy:
  #!/usr/bin/env bash
  set -euo pipefail

  # Remove all files in COMPUTER_DIR before deploy
  if [ -d "${COMPUTER_DIR}" ]; then
    rm -rf "${COMPUTER_DIR:?}/"*
  fi

  # Deploy Computer Scripts
  mkdir -p "${COMPUTER_DIR}"

  exclude_args=()
  for path in ${COMPUTER_EXCLUDES:-}; do
    exclude_args+=(--exclude="$path")
  done

  rsync -a --delete "${exclude_args[@]}" src/ "${COMPUTER_DIR}/"
  echo "Deployed to ${COMPUTER_DIR}"

  # Remove all files in CRAFTER_DIR before deploy
  if [ -d "${CRAFTER_DIR}" ]; then
    rm -rf "${CRAFTER_DIR:?}/"*
  fi

  # Deploy Crafter Scripts
  mkdir -p "${CRAFTER_DIR}"

  for path in ${CRAFTER_INCLUDES:-}; do
    mkdir -p "${CRAFTER_DIR}/$(dirname "$path")"
    rsync -a "src/$path" "${CRAFTER_DIR}/$path"
  done

  echo "Deployed to ${CRAFTER_DIR}"
