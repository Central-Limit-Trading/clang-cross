#!/usr/bin/env bash
# Exercise the actual workflow shell blocks without network or compilation.
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
workflow="${repo_root}/.github/workflows/release.yaml"
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/clang-cross-release-test.XXXXXX")
trap 'rm -rf -- "${test_tmp}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
extract_step() {
    awk -v step="$1" '
      /^      - name:/ { selected = ($0 ~ step); body = 0 }
      selected && /^        run: \|/ { body = 1; next }
      body { sub(/^          /, ""); print }
    ' "$workflow"
}
extract_step 'Create release|Create or update release' > "${test_tmp}/publish.sh"
# Model Actions input expansion in the old workflow, for a red regression test.
sed -i '/TAG="${{ inputs.release_tag }}"/d' "${test_tmp}/publish.sh"
[[ -s "${test_tmp}/publish.sh" ]] || fail 'publish step missing'
bash -n "${test_tmp}/publish.sh"
mkdir "${test_tmp}/bin" "${test_tmp}/release"
cat > "${test_tmp}/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CALLS"
case "$2" in
  view) exit "$VIEW_STATUS" ;;
  upload) exit "$UPLOAD_STATUS" ;;
  edit|create) exit 0 ;;
  *) exit 99 ;;
esac
EOF
chmod +x "${test_tmp}/bin/gh"
export PATH="${test_tmp}/bin:${PATH}" TAG=v0.0.1
export CALLS="${test_tmp}/calls" VIEW_STATUS=0 UPLOAD_STATUS=0
cd "$test_tmp"
for target in gnu musl; do
    for container in amazonlinux2 alinux3 centos7 ubuntu22; do
        package="release/x86_64-unknown-linux-${target}-${container}.tar.xz"
        printf '%s\n' "$package" > "$package"
        sha256sum "$package" | awk '{print $1}' > "${package}.sha256"
    done
done
bash publish.sh > publish.log 2>&1 || fail 'existing release must support overwrite'
grep -q 'release upload .*--clobber' "$CALLS" || fail 'same-name assets not replaced'
grep -q 'release edit .*--notes-file RELEASE.md' "$CALLS" || fail 'release notes not updated'
! grep -q 'release create' "$CALLS" || fail 'existing release recreated'

: > "$CALLS"
export VIEW_STATUS=1
bash publish.sh > publish.log 2>&1 || fail 'new release creation failed'
grep -q 'release create' "$CALLS" || fail 'new release not created'
! grep -q 'release upload' "$CALLS" || fail 'upload before release exists'

: > "$CALLS"
export VIEW_STATUS=0 UPLOAD_STATUS=1
if bash publish.sh > publish.log 2>&1; then fail 'upload failure ignored'; fi
! grep -q 'release edit' "$CALLS" || fail 'notes changed after upload failure'

: > "$CALLS"
export TAG='' UPLOAD_STATUS=0
if bash publish.sh > publish.log 2>&1; then fail 'empty tag accepted'; fi
[[ ! -s "$CALLS" ]] || fail 'empty tag reached API'

extract_step 'Verify artifacts and generate release notes' > verify.sh
[[ -s verify.sh ]] || fail 'artifact verification step missing'
bash -n verify.sh
bash verify.sh > verify.log 2>&1 || fail 'valid artifacts rejected'
[[ $(wc -l < RELEASE.md) -eq 10 ]] || fail 'release notes must list eight packages'
package='release/x86_64-unknown-linux-gnu-ubuntu22.tar.xz'
printf 'corrupt\n' >> "$package"
if bash verify.sh > verify.log 2>&1; then fail 'corrupt package accepted'; fi
printf '%s\n' "$package" > "$package"
mv "${package}.sha256" saved.sha256
if bash verify.sh > verify.log 2>&1; then fail 'missing checksum accepted'; fi
mv saved.sha256 "${package}.sha256"
mv "$package" saved.tar.xz
if bash verify.sh > verify.log 2>&1; then fail 'missing package accepted'; fi

[[ $(grep -c "if: inputs.source_run_id == ''" "$workflow") -eq 2 ]] ||
    fail 'artifact reuse does not skip both matrix and build'
# Match the literal GitHub Actions expression, not a shell expansion.
# shellcheck disable=SC2016
grep -Fq 'run-id: ${{ inputs.source_run_id || github.run_id }}' "$workflow" ||
    fail 'artifact download ignores source run'
grep -Fq "needs.build.result == 'skipped'" "$workflow" ||
    fail 'release-only path rejects skipped builds'
echo 'release workflow regression: PASS'
