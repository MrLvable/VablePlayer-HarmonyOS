#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${LYCIUM_HOME:?LYCIUM_HOME is required (provided by isaced/setup-ohos)}"

RECIPE_DIR="${LYCIUM_HOME}/thirdparty/libsmb2"
mkdir -p "${RECIPE_DIR}"
cp "${PROJECT_ROOT}/libsmb2/HPKBUILD" "${RECIPE_DIR}/HPKBUILD"

(
  cd "${LYCIUM_HOME}/lycium"
  ./build.sh libsmb2
)

for abi in arm64-v8a x86_64; do
  source_dir="${LYCIUM_HOME}/lycium/usr/libsmb2/${abi}"
  destination="${PROJECT_ROOT}/libsmb2/src/main/libs/${abi}"

  test -f "${source_dir}/lib/libsmb2.so.1"
  mkdir -p "${destination}"
  rm -f "${destination}/libsmb2.so" "${destination}/libsmb2.so.1"
  # Normalize the versioned SONAME (libsmb2.so.1) to the plain file name
  # (libsmb2.so) that hvigor packages into the HAR. A solid file without a
  # symlink keeps ProcessLibs happy on both macOS and Linux.
  cp -L "${source_dir}/lib/libsmb2.so.1" "${destination}/libsmb2.so"
  python3 "${PROJECT_ROOT}/scripts/patch-soname.py" "${destination}/libsmb2.so" libsmb2.so
done

diff -ru \
  "${LYCIUM_HOME}/lycium/usr/libsmb2/arm64-v8a/include/smb2" \
  "${PROJECT_ROOT}/libsmb2/src/main/cpp/include/smb2"
