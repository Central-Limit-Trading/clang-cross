#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 <target> <toolchain-dir> <clang-version> <musl-version> <loader-name>" >&2
    exit 64
}

[[ $# -eq 5 ]] || usage

target=$1
toolchain_dir=$2
expected_clang=$3
expected_musl=$4
loader_name=$5
cc="${toolchain_dir}/bin/${target}-clang"
cxx="${toolchain_dir}/bin/${target}-clang++"
lld="${toolchain_dir}/bin/ld.lld"
sysroot="${toolchain_dir}/${target}/sysroot"
loader="${sysroot}/lib/${loader_name}"
verify_cflags=(-Wall -Wextra -Werror)

[[ -x "${cc}" ]] || { echo "compiler not found: ${cc}" >&2; exit 1; }
[[ -x "${cxx}" ]] || { echo "C++ compiler not found: ${cxx}" >&2; exit 1; }
[[ -x "${lld}" ]] || { echo "LLD not found: ${lld}" >&2; exit 1; }
[[ -x "${loader}" ]] || { echo "musl loader not found: ${loader}" >&2; exit 1; }

clang_output=$("${cc}" --version)
grep -Fq "clang version ${expected_clang}" <<<"${clang_output}" || {
    echo "Clang version mismatch: ${clang_output}" >&2
    exit 1
}
loader_output=$("${loader}" 2>&1 || true)
grep -Fq "Version ${expected_musl}" <<<"${loader_output}" || {
    echo "musl version mismatch: ${loader_output}" >&2
    exit 1
}

verify_tmp=$(mktemp -d "${TMPDIR:-/tmp}/clang-cross-verify.XXXXXX")
cleanup() { rm -rf -- "${verify_tmp}"; }
trap cleanup EXIT

runtime_dirs=("${sysroot}/lib" "${sysroot}/usr/lib")
for runtime in libgcc_s.so.1 libstdc++.so.6; do
    runtime_path=$("${cc}" -print-file-name="${runtime}")
    [[ "${runtime_path}" != "${runtime}" && -e "${runtime_path}" ]] || {
        echo "target runtime not found: ${runtime}" >&2
        exit 1
    }
    runtime_dirs+=("$(dirname "${runtime_path}")")
done
runtime_library_path=$(IFS=:; echo "${runtime_dirs[*]}")

run_dynamic() {
    "${loader}" --library-path "${runtime_library_path}" "$@"
}

expect_failure() {
    local name=$1 pattern=$2 program=$3 output status
    set +e
    output=$(run_dynamic "${program}" 2>&1)
    status=$?
    set -e
    [[ ${status} -ne 0 ]] || { echo "${name} unexpectedly succeeded" >&2; exit 1; }
    grep -Eq "${pattern}" <<<"${output}" || {
        echo "${name} diagnostic missing: ${output}" >&2
        exit 1
    }
}

expect_tsan_failure() {
    local program=$1 output status
    local machine=${target%%-*}
    command -v setarch >/dev/null || {
        echo "setarch is required for the TSan no-ASLR runtime check" >&2
        exit 1
    }
    set +e
    output=$(setarch "${machine}" -R "${loader}" \
        --library-path "${runtime_library_path}" "${program}" 2>&1)
    status=$?
    set -e
    [[ ${status} -ne 0 ]] || { echo "TSan unexpectedly succeeded" >&2; exit 1; }
    grep -Eq 'ThreadSanitizer: data race|WARNING: ThreadSanitizer' <<<"${output}" || {
        echo "TSan diagnostic missing: ${output}" >&2
        exit 1
    }
}

cat >"${verify_tmp}/hello.c" <<'EOF'
#include <stdio.h>
int main(void) { puts("C PASS"); return 0; }
EOF
"${cc}" "${verify_cflags[@]}" -static -fuse-ld=lld "${verify_tmp}/hello.c" -o "${verify_tmp}/hello-c"
[[ "$("${verify_tmp}/hello-c")" == "C PASS" ]]

cat >"${verify_tmp}/hello.cc" <<'EOF'
#include <iostream>
int main() { std::cout << "C++ PASS\n"; }
EOF
"${cxx}" "${verify_cflags[@]}" -static -fuse-ld=lld "${verify_tmp}/hello.cc" -o "${verify_tmp}/hello-cxx"
[[ "$("${verify_tmp}/hello-cxx")" == "C++ PASS" ]]

"${cc}" "${verify_cflags[@]}" -fuse-ld=lld "${verify_tmp}/hello.c" -o "${verify_tmp}/hello-dynamic"
[[ "$(run_dynamic "${verify_tmp}/hello-dynamic")" == "C PASS" ]]
"${lld}" --version | grep -Fq "LLD ${expected_clang}"

cat >"${verify_tmp}/iconv.c" <<'EOF'
#include <iconv.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(void) {
    iconv_t cd = iconv_open("UTF-8", "GB18030");
    char input[] = { (char)0x90, 0x30, (char)0x81, 0x30 };
    const unsigned char expected[] = { 0xf0, 0x90, 0x80, 0x80 };
    char output[8] = {0}, *in_ptr = input, *out_ptr = output;
    size_t in_left = sizeof(input), out_left = sizeof(output);
    if (cd == (iconv_t)-1) return 1;
    alarm(5);
    if (iconv(cd, &in_ptr, &in_left, &out_ptr, &out_left) == (size_t)-1) return 2;
    alarm(0);
    iconv_close(cd);
    if (in_left || (size_t)(out_ptr-output) != sizeof(expected)) return 3;
    if (memcmp(output, expected, sizeof(expected))) return 4;
    puts("iconv PASS");
    return 0;
}
EOF
"${cc}" "${verify_cflags[@]}" -fuse-ld=lld "${verify_tmp}/iconv.c" -o "${verify_tmp}/iconv"
[[ "$(run_dynamic "${verify_tmp}/iconv")" == "iconv PASS" ]]

cat >"${verify_tmp}/asan.c" <<'EOF'
#include <stdlib.h>
int main(void) { char *p=malloc(4); p[8]=1; return p[8]; }
EOF
"${cc}" "${verify_cflags[@]}" -O0 -g -fsanitize=address -fno-omit-frame-pointer "${verify_tmp}/asan.c" -o "${verify_tmp}/asan"
expect_failure ASan AddressSanitizer "${verify_tmp}/asan"

cat >"${verify_tmp}/ubsan.c" <<'EOF'
#include <limits.h>
int main(void) { volatile int v=INT_MAX; return v+1; }
EOF
"${cc}" "${verify_cflags[@]}" -O0 -g -fsanitize=undefined -fno-sanitize-recover=undefined "${verify_tmp}/ubsan.c" -o "${verify_tmp}/ubsan"
expect_failure UBSan 'runtime error|signed integer overflow' "${verify_tmp}/ubsan"

cat >"${verify_tmp}/lsan.c" <<'EOF'
#include <stdlib.h>
int main(void) {
    void *leaked = malloc(128);
    if (!leaked) return 1;
    ((volatile unsigned char *)leaked)[0] = 1;
    leaked = NULL;
    return leaked != NULL;
}
EOF
"${cc}" "${verify_cflags[@]}" -O0 -g -fsanitize=leak "${verify_tmp}/lsan.c" -o "${verify_tmp}/lsan"
expect_failure LSan 'LeakSanitizer|detected memory leaks' "${verify_tmp}/lsan"

cat >"${verify_tmp}/tsan.c" <<'EOF'
#include <pthread.h>
enum { THREAD_COUNT = 2, INCREMENTS = 100000 };
static pthread_barrier_t start_barrier;
static int shared;
static void *write_shared(void *p) {
    (void)p;
    (void)pthread_barrier_wait(&start_barrier);
    for (int i = 0; i < INCREMENTS; ++i) shared++;
    return 0;
}
int main(void) {
    pthread_t threads[THREAD_COUNT];
    if (pthread_barrier_init(&start_barrier, 0, THREAD_COUNT + 1) != 0) return 1;
    for (int i = 0; i < THREAD_COUNT; ++i)
        if (pthread_create(&threads[i], 0, write_shared, 0) != 0) return 2;
    (void)pthread_barrier_wait(&start_barrier);
    for (int i = 0; i < THREAD_COUNT; ++i)
        if (pthread_join(threads[i], 0) != 0) return 3;
    if (pthread_barrier_destroy(&start_barrier) != 0) return 4;
    return 0;
}
EOF
"${cc}" "${verify_cflags[@]}" -O0 -g -fsanitize=thread -pthread "${verify_tmp}/tsan.c" -o "${verify_tmp}/tsan"
expect_tsan_failure "${verify_tmp}/tsan"

echo "clang toolchain runtime verification: PASS"
