#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 <archive-url> <destination-directory>" >&2
    exit 64
}

[[ $# -eq 2 ]] || usage

archive_url=$1
destination=$2
download_tmp=$(mktemp -d "${TMPDIR:-/tmp}/clang-cross-download.XXXXXX")
cleanup() { rm -rf -- "${download_tmp}"; }
trap cleanup EXIT

archive="${download_tmp}/toolchain.tar.xz"
sidecar="${archive}.sha256"
extract_dir="${download_tmp}/extract"

curl --fail --silent --show-error --location --retry 3 --retry-delay 5 \
    --output "${archive}" "${archive_url}"
curl --fail --silent --show-error --location --retry 3 --retry-delay 5 \
    --output "${sidecar}" "${archive_url}.sha256"

expected_hash=$(awk 'NF {print $1; exit}' "${sidecar}")
if ! [[ "${expected_hash}" =~ ^[[:xdigit:]]{64}$ ]]; then
    echo "Error: invalid SHA-256 sidecar for ${archive_url}" >&2
    exit 1
fi

actual_hash=$(sha256sum "${archive}" | awk '{print $1}')
if [[ "${actual_hash,,}" != "${expected_hash,,}" ]]; then
    echo "Error: SHA-256 mismatch for ${archive_url}" >&2
    echo "Expected: ${expected_hash}" >&2
    echo "Actual:   ${actual_hash}" >&2
    exit 1
fi
echo "Checksum verification passed: ${archive_url}"

mkdir -p "${extract_dir}"
tar -xJf "${archive}" -C "${extract_dir}"
mkdir -p "${destination}"
cp -a "${extract_dir}/." "${destination}/"

echo "Successfully downloaded and extracted toolchain"
