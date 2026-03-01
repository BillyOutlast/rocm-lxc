#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: reassemble-template.sh <part-prefix> [output-file]

Examples:
  reassemble-template.sh rocm-dev-ubuntu-24.04-7.2-complete.tar.gz
  reassemble-template.sh rocm-dev-ubuntu-24.04-7.2-complete.tar.gz rebuilt.tar.gz

This script expects split files named like:
  <part-prefix>.000.part
  <part-prefix>.001.part
  ...
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

PART_PREFIX="${1:-}"
OUTPUT_FILE="${2:-${PART_PREFIX}}"

if [[ -z "${PART_PREFIX}" ]]; then
  usage >&2
  exit 1
fi

shopt -s nullglob
PARTS=("${PART_PREFIX}".*.part)
shopt -u nullglob

if [[ "${#PARTS[@]}" -eq 0 ]]; then
  echo "No part files found for prefix: ${PART_PREFIX}" >&2
  exit 1
fi

echo "Reassembling ${#PARTS[@]} parts into ${OUTPUT_FILE}"
cat "${PART_PREFIX}".*.part > "${OUTPUT_FILE}"

echo "Done: ${OUTPUT_FILE}"

CHECKSUM_FILE="${PART_PREFIX}.parts.sha256"
if [[ -f "${CHECKSUM_FILE}" ]]; then
  echo "Verifying part checksums with ${CHECKSUM_FILE}"
  sha256sum -c "${CHECKSUM_FILE}"
fi
