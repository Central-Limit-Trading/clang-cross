# compiler-rt musl patches (x86_64-unknown-linux-musl)

These patches make LLVM `compiler-rt` build the sanitizer runtimes
(ASan / LSan / UBSan / TSan / MSan / DFSan) against **musl libc**.
They are applied to the `llvm/` submodule source tree by
`scripts/make` (function `build_compiler_rt`) right before the
compiler-rt runtimes build, and reverted afterwards so the submodule
stays clean.

## Provenance (pinned, reproducible)

- Upstream: Alpine Linux `aports`, package `main/llvm-runtimes`
- aports commit: `cee27a97e6e5015af47b37adec882d6d11457a6b` (2026-05-19)
- aports `llvm-runtimes` `pkgver=22.1.3`
- Matches our `llvm` submodule pin: tag `llvmorg-22.1.3`
  (commit `e9846648fd6183ee6d8cbdb4502213fcf902a211`)

The patches are applied with GNU `patch`'s default fuzz (= 2), exactly
as Alpine's `abuild` / `default_prepare` does (`patch -p1`). Version
alignment (LLVM 22.1.3 ⇔ aports 22.1.3) guarantees this *fuzz-tolerant*
application succeeds — it does **not** mean fuzz 0. `0002` is a
long-lived Alpine carry patch (dated 2022) whose context drifts across
LLVM releases (e.g. 22.1.3 inserts a `SANITIZER_HAIKU` block between the
includes and the NETBSD block), so a small fuzz/offset is expected and
intentional. Verified: all three patches apply at default fuzz on the
pinned 22.1.3 source (0002 Hunk #1 succeeds with fuzz 2).

## Support tier

- Tier 1: ASan / UBSan / LSan.
- Tier 2: TSan. Runtime/link support is built for x86_64; keep smoke tests
  as the acceptance signal because musl coverage is thinner than glibc.
- Tier 3: MSan / DFSan / MemProf. Runtimes are built, but useful results
  need an instrumented dependency closure. Treat as experimental.

## Files

| File | Upstream name | Purpose on x86_64-musl |
|------|---------------|------------------------|
| `0001-fix-msan-with-musl.patch` | `fix-msan-with-musl.patch` | Guard the `__getrlimit` MSan interceptor with `SANITIZER_GLIBC`; without it MSan fails to link on musl (`struct_rlimit64_sz` undefined). **Required for MSan.** |
| `0002-compiler-rt-lsan-dtp-offset.patch` | `compiler-rt-lsan-dtp-offset.patch` | Guard `TlsPreTcbSize()` with `SANITIZER_GLIBC` + add `DTP_OFFSET` (0 on x86_64). Fixes LSan/TLS scanning on musl. **Required for LSan/TLS.** |
| `0003-compiler-rt-sanitizer-supported-arch.patch` | `compiler-rt-sanitizer-supported-arch.patch` | Narrows `ALL_SANITIZER_COMMON_SUPPORTED_ARCH`. Effectively a no-op for x86_64 (kept for parity with Alpine). |

## sha512 (verified against the aports APKBUILD `sha512sums`)

```
0a4f0b5ae82f93387e8880c6e293eef9234f0cb4dadf7c52846f1a45612b931d2b460579d08d48548de9a7e6372b75f95e05e32683a60911a3d48f567cd4808b  0001-fix-msan-with-musl.patch
5830e0738e817aba515b2d5600a11a45f8e93ad9b39aae2b1561d7dd4dcea9361c66d7295aef0ae0728b23092643dc0affdfd4215f173ca5552c28ca072c731a  0002-compiler-rt-lsan-dtp-offset.patch
7754a0b6d5d65bc7bcc35d8d16d43c21e202a068ae729508d2d00a3e32b88483763666a9ec3130f8be4cefd59aee30f2bd46f07e6bef0519084c05a96342fdcc  0003-compiler-rt-sanitizer-supported-arch.patch
```

## Updating

When bumping the `llvm` submodule, bump Alpine `aports` in lockstep:
re-fetch these three files from the `main/llvm-runtimes` directory at
an aports commit whose `pkgver` matches the new LLVM version, update
the commit hash and sha512 list above, and re-run the verification
build.
