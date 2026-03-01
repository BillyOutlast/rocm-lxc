#!/usr/bin/env bash
set -euo pipefail

IMAGE="${IMAGE:-rocm/dev-ubuntu-24.04:7.2-complete}"
OUTPUT_DIR="${OUTPUT_DIR:-dist}"
TEMPLATE_NAME="${TEMPLATE_NAME:-rocm-dev-ubuntu-24.04-7.2-complete}"

WORK_DIR="$(mktemp -d)"
ROOTFS_DIR="${WORK_DIR}/rootfs"
mkdir -p "${ROOTFS_DIR}" "${OUTPUT_DIR}"

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

echo "Pulling image: ${IMAGE}"
docker pull "${IMAGE}"

CONTAINER_ID="$(docker create "${IMAGE}")"
cleanup_container() {
  docker rm -f "${CONTAINER_ID}" >/dev/null 2>&1 || true
}
trap cleanup_container EXIT

echo "Exporting filesystem..."
docker export "${CONTAINER_ID}" | tar -x -C "${ROOTFS_DIR}"

# Cleanup a few container-runtime leftovers that are not useful in LXC templates.
rm -f "${ROOTFS_DIR}/.dockerenv" || true
rm -f "${ROOTFS_DIR}/run/.containerenv" || true

# Ensure /tmp exists with expected permissions.
mkdir -p "${ROOTFS_DIR}/tmp"
chmod 1777 "${ROOTFS_DIR}/tmp"

OUT_FILE="${OUTPUT_DIR}/${TEMPLATE_NAME}.tar.gz"

# GNU tar options preserve numeric owners for predictable import behavior.
echo "Packing template: ${OUT_FILE}"
tar --numeric-owner --xattrs --acls -czf "${OUT_FILE}" -C "${ROOTFS_DIR}" .

sha256sum "${OUT_FILE}" > "${OUT_FILE}.sha256"

echo "Done"
echo "Template: ${OUT_FILE}"
echo "Checksum: ${OUT_FILE}.sha256"
