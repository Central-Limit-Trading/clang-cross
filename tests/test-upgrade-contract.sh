#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
make_script="${repo_root}/scripts/make"
download_script="${repo_root}/scripts/download-toolchain.sh"
runtime_verifier="${repo_root}/scripts/verify-toolchain.sh"
docker_build_script="${repo_root}/scripts/build-with-docker.sh"
workflow="${repo_root}/.github/workflows/release.yaml"
musl_config="${repo_root}/targets/x86_64-unknown-linux-musl/config"
patch_readme="${repo_root}/targets/x86_64-unknown-linux-musl/patches/README.md"
expected_llvm=ca7933e47d3a3451d81e72ac174dcb5aa28b59d1

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/clang-cross-download-test.XXXXXX")
cleanup() { rm -rf -- "${test_tmp}"; }
trap cleanup EXIT

actual_llvm=$(git -C "${repo_root}/llvm" rev-parse HEAD)
[[ "${actual_llvm}" == "${expected_llvm}" ]] ||
    fail "llvm is ${actual_llvm}, expected ${expected_llvm}"
[[ "$(git -C "${repo_root}/llvm" describe --exact-match --tags HEAD)" == llvmorg-22.1.8 ]] ||
    fail "llvmorg-22.1.8 tag is not checked out"
[[ -z "$(git -C "${repo_root}/llvm" status --porcelain)" ]] ||
    fail "llvm submodule is not clean"

grep -qx 'LLVM_VERSION="22.1.8"' "${make_script}" ||
    fail "LLVM_VERSION is not 22.1.8"
grep -qx 'LLVM_SOURCE_REVISION="ca7933e47d3a3451d81e72ac174dcb5aa28b59d1"' "${make_script}" ||
    fail "LLVM source revision is not enforced"
grep -qx 'LLVM_ARCHIVE="clang-cross-${LLVM_VERSION}.tar.xz"' "${make_script}" ||
    fail "LLVM cache is not versioned"
grep -qx 'GNU_CROSS_VERSION="v0.0.1"' "${make_script}" ||
    fail "GNU base-toolchain version changed unexpectedly"
grep -qx 'MUSL_CROSS_VERSION="v1.2.6-r1"' "${make_script}" ||
    fail "musl base-toolchain release is not v1.2.6-r1"

verify_function="${test_tmp}/verify-llvm-source.sh"
awk '/^verify_llvm_source\(\) \{/,/^}/ { print }' "${make_script}" > "${verify_function}"
[[ -s "${verify_function}" ]] || fail "verify_llvm_source function is missing"
mkdir "${test_tmp}/fake-bin"
cat > "${test_tmp}/fake-bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 4 || "$1" != -c ||
      "$2" != "safe.directory=${EXPECTED_SAFE_DIRECTORY}" ||
      "$3" != rev-parse || "$4" != HEAD ]]; then
    echo "unsupported git invocation: $*" >&2
    exit 129
fi
printf '%s\n' "${EXPECTED_LLVM_REVISION}"
EOF
chmod +x "${test_tmp}/fake-bin/git"
(
    export PROJECT_ROOT="${repo_root}"
    export LLVM_SOURCE_REVISION="${expected_llvm}"
    export PATH="${test_tmp}/fake-bin:${PATH}"
    export EXPECTED_SAFE_DIRECTORY="${repo_root}/llvm"
    export EXPECTED_LLVM_REVISION="${expected_llvm}"
    # shellcheck source=/dev/null
    source "${verify_function}"
    verify_llvm_source
) || fail "LLVM revision verification is not compatible with old Git and safe.directory"

! grep -Eq '^(RELEASE_VERSION|CT_VER)=' "${make_script}" ||
    fail "shared base-toolchain release variable remains"
! grep -q 'clang-cross\.tar\.xz' "${make_script}" ||
    fail "unversioned LLVM cache remains active"
grep -q 'verify_base_toolchain' "${make_script}" ||
    fail "downloaded base toolchain is not version-checked"
[[ -x "${runtime_verifier}" ]] || fail "runtime verifier is not executable"
bash -n "${runtime_verifier}"
grep -q 'verify-toolchain.sh' "${make_script}" ||
    fail "runtime verifier is not invoked before packaging"
grep -q 'setarch.*-R' "${runtime_verifier}" ||
    fail "TSan is not executed with ASLR disabled"
grep -q 'pthread_barrier_init' "${runtime_verifier}" ||
    fail "TSan race test does not synchronize worker startup"
grep -q 'pthread_barrier_wait' "${runtime_verifier}" ||
    fail "TSan race test does not create a deterministic race window"
grep -q 'leaked = NULL' "${runtime_verifier}" ||
    fail "LSan test leaves its allocation reachable"
grep -q 'verify_cflags=.*-Werror' "${runtime_verifier}" ||
    fail "runtime verifier does not reject compiler warnings"
grep -q -- '--security-opt seccomp=unconfined' "${docker_build_script}" ||
    fail "container does not permit the TSan no-ASLR personality"
grep -q 'Checksum verification passed' "${docker_build_script}" ||
    fail "renamed artifact checksum is not verified"
grep -Fq 'sha256sum --check -' "${docker_build_script}" ||
    fail "renamed artifact checksum gate is not executable"
grep -Fq 'verify_file_checksum "${TARGET}.tar.xz"' "${make_script}" ||
    fail "direct target package checksum is not verified"

[[ -x "${download_script}" ]] || fail "download helper is not executable"
bash -n "${download_script}"

mkdir -p "${test_tmp}/source/x86_64-unknown-linux-musl"
printf 'verified\n' > "${test_tmp}/source/x86_64-unknown-linux-musl/marker"
tar -cJf "${test_tmp}/toolchain.tar.xz" -C "${test_tmp}/source" x86_64-unknown-linux-musl
sha256sum "${test_tmp}/toolchain.tar.xz" | awk '{print $1}' > "${test_tmp}/toolchain.tar.xz.sha256"
mkdir "${test_tmp}/good"
"${download_script}" "file://${test_tmp}/toolchain.tar.xz" "${test_tmp}/good"
[[ "$(cat "${test_tmp}/good/x86_64-unknown-linux-musl/marker")" == verified ]] ||
    fail "verified archive was not extracted"

printf '%064d\n' 0 > "${test_tmp}/toolchain.tar.xz.sha256"
mkdir "${test_tmp}/bad"
if "${download_script}" "file://${test_tmp}/toolchain.tar.xz" "${test_tmp}/bad" >/dev/null 2>&1; then
    fail "bad checksum unexpectedly succeeded"
fi
[[ -z "$(find "${test_tmp}/bad" -mindepth 1 -print -quit)" ]] ||
    fail "bad checksum extracted files"

grep -qx 'EXPECTED_BASE_GCC_VERSION=16.1.0' "${musl_config}" ||
    fail "expected GCC version is missing"
grep -qx 'EXPECTED_MUSL_VERSION=1.2.6' "${musl_config}" ||
    fail "expected musl version is missing"
grep -qx 'EXPECTED_MUSL_LOADER=ld-musl-x86_64.so.1' "${musl_config}" ||
    fail "expected musl loader is missing"

grep -q '8b4d1f88aca8bd81cda4422a6cafaf11813d8a07' "${patch_readme}" ||
    fail "Alpine 22.1.8 provenance is missing"
grep -q 'llvmorg-22.1.8' "${patch_readme}" ||
    fail "patch documentation does not name LLVM 22.1.8"
for patch_file in "${repo_root}"/targets/x86_64-unknown-linux-musl/patches/*.patch; do
    patch --dry-run --fuzz=2 --batch -d "${repo_root}/llvm" -Np1 < "${patch_file}" >/dev/null ||
        fail "patch does not apply: $(basename "${patch_file}")"
done

grep -q "needs.build.result == 'success'" "${workflow}" ||
    fail "release is not gated on a successful build matrix"
grep -q "inputs.containers == 'all'" "${workflow}" ||
    fail "release can be created from a partial container selection"
grep -q "default: 'x86_64-unknown-linux-gnu,x86_64-unknown-linux-musl'" "${workflow}" ||
    fail "default release target selection does not build GNU and musl"
grep -q "inputs.targets == 'x86_64-unknown-linux-gnu,x86_64-unknown-linux-musl'" "${workflow}" ||
    fail "release can be created from a noncanonical target selection"
release_targets=$(sed -n "/^      targets:/,/^      containers:/s/^[[:space:]]*default: '\(.*\)'/\1/p" "${workflow}")
IFS=',' read -r -a release_target_list <<< "${release_targets}"
release_container_count=$(grep -cE '^[[:space:]]+containers\[[^]]+\]=' "${workflow}")
release_asset_count=$((${#release_target_list[@]} * release_container_count * 2))
[[ "${release_asset_count}" -eq 16 ]] ||
    fail "full release produces ${release_asset_count} assets, expected 16"
grep -Fq 'pattern: "*.tar.*"' "${workflow}" ||
    fail "release does not download both packages and checksum artifacts"
grep -Fq 'release/*.tar.xz release/*.sha256' "${workflow}" ||
    fail "release does not publish packages and checksum sidecars"
! grep -q 'docker cp .*:/workspace/clang-cross/' "${workflow}" ||
    fail "workflow copies artifacts over their bind-mounted source paths"
grep -Fq 'sha256sum --check -' "${workflow}" ||
    fail "workflow does not verify bind-mounted artifacts"
! grep -q "needs.build.result == 'failure'" "${workflow}" ||
    fail "release still admits a failed matrix"
! grep -q -- '--clobber' "${workflow}" ||
    fail "release can overwrite assets"
grep -q 'already exists; refusing to overwrite' "${workflow}" ||
    fail "existing release rejection is missing"
! grep -q "github.event_name == 'release'" "${workflow}" ||
    fail "published-release recursion remains"

echo "clang/musl upgrade contract: PASS"
