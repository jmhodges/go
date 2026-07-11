# Reusing Go's crypto assembly from a Rust library

Research notes on taking the assembly that backs `crypto/tls` in this tree and
turning it into something a Rust crate can link and call. A small end-to-end
proof of concept lives in `demo/` — Go assembly from `crypto/cipher`, extracted
and running inside a Rust binary via a C-ABI shim.

## TL;DR

- `crypto/tls` itself contains no assembly. The assembly lives in the packages
  its ciphersuites call into: `crypto/aes` (AES + AES-GCM), `crypto/elliptic`
  (P-256), `crypto/sha1`/`sha256`/`sha512`, `crypto/md5`, `crypto/cipher`
  (XOR for CBC), `math/big` (RSA/ECDSA bignum kernels), and the vendored
  `golang.org/x/crypto` (ChaCha20-Poly1305, Poly1305, Curve25519).
- Go assembly is written in Plan 9 syntax, consumed **only** by Go's own
  assembler, which emits Go's own object format (goobj) — not ELF. Rust's
  linker can't consume any of it directly, and there is no off-the-shelf
  Plan9→GAS translator (all existing tools go the *other* way:
  [c2goasm](https://github.com/minio/c2goasm),
  [gocc](https://github.com/kelindar/gocc), avo).
- Three viable strategies, in increasing order of effort and decreasing order
  of pragmatism:
  1. **Use the upstream twin.** Nearly every asm file here has a non-Go
     original that Rust crypto libraries already consume (see "Provenance").
  2. **Machine-code extraction.** `go tool asm` + `go tool objdump -gnu`
     gives you exact instruction bytes and GNU-syntax mnemonics; wrap the
     bytes in a `.S` file with a small C-ABI shim. Works today for
     self-contained leaf functions — demonstrated in `demo/`.
  3. **Mechanical textual translation** to GAS syntax, using the
     `objdump -gnu` output as an oracle. Required for functions that
     reference constant tables.
- Whatever the route, four ABI hazards must be handled; all four were
  verified concretely against this tree (see "Hazards").

## Where the assembly is (this tree, go1.13 era)

| TLS use | Package | Files (amd64) | Notes |
|---|---|---|---|
| AES-GCM ciphersuites | `crypto/aes` | `asm_amd64.s`, `gcm_amd64.s` | AES-NI + CLMUL, Gueron/Krasnov |
| ChaCha20-Poly1305 | vendored `x/crypto/chacha20poly1305` | `chacha20poly1305_amd64.s` | Vlad Krasnov, CL 24717 |
| ECDHE P-256 | `crypto/elliptic` | `p256_asm_amd64.s` | Gueron–Krasnov, constant-time |
| X25519 | vendored `x/crypto/curve25519` | `*_amd64.s` (5 files) | from SUPERCOP amd64-51 |
| Handshake hashes / PRF | `crypto/sha1`, `sha256`, `sha512`, `md5` | `*block_amd64.s` | SSE/AVX2 block functions |
| CBC suites | `crypto/cipher` | `xor_amd64.s` | used by the demo |
| RSA / ECDSA bignum | `math/big` | `arith_amd64.s` | 11 TEXT symbols (mulAddVWW etc.) |

All of it is ABI0 (this predates Go 1.17's register ABI): arguments and
results are read from the caller's stack frame at fixed offsets from the `FP`
pseudo-register. That is actually good news for extraction — ABI0 is simple
and stable.

## Why it can't be linked as-is

1. **Syntax**: Plan 9 asm (`MOVQ dst+0(FP), BX`, `TEXT ·gcmAesEnc(SB),0,$256-96`)
   is parsed only by `cmd/asm`. GAS, LLVM's integrated assembler, and Rust's
   `global_asm!` cannot read it.
2. **Object format**: `go tool asm` emits goobj, not ELF. You cannot hand the
   `.o` to `rustc`/`ld`, and `objcopy` doesn't understand it.
3. **Calling convention**: ABI0 passes everything on the stack. For
   `func xorBytesSSE2(dst, a, b *byte, n int)` the body reads
   `0x8(%rsp)`…`0x20(%rsp)` (first slot after the return address). System V
   passes those in `rdi, rsi, rdx, rcx`. Return values are also stack slots
   (e.g. `p256PointAddAsm` writes its `int` result to `ret+72(FP)`).
4. **Runtime hooks**: any `TEXT` that is not `NOSPLIT` and has a frame gets a
   stack-split prologue *inserted by the assembler*. Verified on
   `gcmAesEnc` (`$256-96`):

   ```
   MOVQ FS:0, R14            // load g from TLS      [R_TLS_LE]
   LEAQ 0xffffff78(SP), R12
   CMPQ R12, 0x10(R14)       // compare g.stackguard0
   JBE  ...                  // CALL runtime.morestack_noctxt  [R_CALL]
   ```

   That is a hard dependency on the Go runtime (goroutine descriptor in TLS,
   `runtime.morestack_noctxt`). Re-assembling with `NOSPLIT` added to the
   `TEXT` line removes it completely — verified: the prologue becomes a plain
   `push %rbp; mov %rsp,%rbp; sub $0x100,%rsp` and the object contains zero
   `morestack` references. The frames in question (256–680 bytes) are trivially
   safe on system threads. Affected functions in this tree include
   `gcmAesEnc`/`gcmAesDec` ($256/$128), `chacha20Poly1305Seal`/`Open` ($288),
   `p256PointAddAsm` ($680), `p256PointAddAffineAsm` ($512),
   `p256PointDoubleAsm` (already NOSPLIT), `ladderstep` ($296).

## Strategy 1 (recommended for crypto): go to the upstream twin

The Go asm was in most cases *derived from* code that already exists in a
form Rust libraries consume:

- `chacha20poly1305_amd64.s` — written by Vlad Krasnov (CloudFlare), who wrote
  the same kernels as OpenSSL perlasm (`chacha20_poly1305_x86_64.pl`); *ring*
  and aws-lc-rs already ship them.
- `p256_asm_amd64.s` — the Gueron–Krasnov `ecp_nistz256` implementation;
  present in OpenSSL/BoringSSL perlasm and already used by *ring*.
- `gcm_amd64.s` — Gueron/Krasnov AES-NI+CLMUL GCM; OpenSSL's
  `aesni-gcm-x86_64.pl` is the same lineage.
- `sha256block_amd64.s` / `sha512block_amd64.s` — Intel reference
  implementations, also available as perlasm.
- `curve25519/*_amd64.s` — Langley's port of SUPERCOP `amd64-51`; the original
  qhasm/asm exists in SUPERCOP, and Rust has curve25519-dalek.

*ring*'s build (perlasm → GAS → `cc`) is the proven production pipeline for
"this assembly, inside a Rust library." If the goal is the *algorithms* rather
than the literal Go bytes, this is the path with the least invented machinery.

## Strategy 2: machine-code extraction (demonstrated in `demo/`)

Pipeline, using any modern host Go toolchain:

```sh
go tool asm -I "$(go env GOROOT)/pkg/include" -p demo -o xor.o xor_amd64.s
go tool objdump -gnu xor.o     # bytes + Plan9 + GNU syntax per instruction
```

`go tool objdump -gnu` prints, for every instruction, its exact encoding and
its GNU-assembler spelling — this is the load-bearing trick:

```
xor_amd64.s:9  0x466  488b5c2408  MOVQ 0x8(SP), BX  // mov 0x8(%rsp),%rbx
```

For a **self-contained leaf function** (no constant tables, no calls out),
the instruction bytes are position-independent: internal branches are
relative, arguments are stack-relative. So you can emit them verbatim as
`.byte` directives into a `.S` file behind a C-ABI shim that lays the
arguments out where ABI0 expects them:

```asm
go_xor_bytes_sse2:            # SysV: rdi=dst rsi=a rdx=b rcx=n
    push   %rbx               # Go clobbers rbx; SysV says preserve it
    sub    $0x20, %rsp
    mov    %rdi, 0x0(%rsp)    # dst  -> FP+0
    mov    %rsi, 0x8(%rsp)    # a    -> FP+8
    mov    %rdx, 0x10(%rsp)   # b    -> FP+16
    mov    %rcx, 0x18(%rsp)   # n    -> FP+24
    call   .Lgo_body          # after CALL, body sees dst at 0x8(%rsp)
    add    $0x20, %rsp
    pop    %rbx
    ret
.Lgo_body:
    .byte 0x48, 0x8b, ...     # extracted Go machine code
```

`demo/` does exactly this for `crypto/cipher`'s `xorBytesSSE2` and verifies
the result from Rust (`cargo run` prints OK for lengths 1…1000). Build wiring
is the standard `cc` crate in `build.rs`; `global_asm!` would work equally.

**Limitation**: functions that reference `DATA`/`GLOBL` constants (GCM's
`bswapMask<>`, ChaCha's polynomial constants, P-256's `p256const*`) carry
unresolved `R_PCREL` relocations in the unlinked object — the displacement
bytes are zero placeholders:

```
MOVDQU 0(IP), X15   // movdqu (%rip),%xmm15   [5:9]R_PCREL:bswapMask<>
```

Raw byte extraction would silently produce code that loads garbage. Those
functions need Strategy 3 (the reloc names in the objdump output tell you
exactly which sites to fix, so a script can also patch bytes + emit the
rodata, but at that point textual translation is cleaner).

## Strategy 3: mechanical textual translation to GAS

For the constant-bearing functions, generate a real `.S` file instead of a
blob:

1. Emit each instruction from the `-gnu` column of
   `go tool objdump -gnu` (it already resolved Plan 9 names, operand order,
   and pseudo-registers to concrete GNU syntax).
2. Re-materialize branch targets as local labels (the dump gives you the
   offsets), and `CALL`s to same-file helpers (P-256's `p256MulInternal` etc.)
   as calls to local labels.
3. Emit each `DATA`/`GLOBL` block as `.section .rodata` + a label, so the
   system assembler regenerates the same `%rip`-relative references the
   `R_PCREL` relocations describe.
4. Replace the ABI0 argument loads (`0x8(%rsp)`… at entry) with SysV register
   moves, or keep them and use the shim pattern from Strategy 2.
5. Add `NOSPLIT` before assembling (or equivalently: drop the morestack
   prologue), and save/restore the SysV callee-saved registers the function
   uses.

No public tool does this today ([golang/go#29538](https://github.com/golang/go/issues/29538)
is the closest discussion); for a fixed set of files it is a few hundred lines
of scripting because the objdump output does the hard parsing for you.

## Hazards checklist (each verified against this tree)

| Hazard | Detail | Fix |
|---|---|---|
| ABI0 args/results on stack | args at `FP+0…`, i.e. `rsp+8…` after CALL; results are stack slots too (`p256PointAddAsm` → `ret+72(FP)`) | shim stores SysV regs to the ABI0 layout, loads result slot into `%rax` after the call |
| Callee-saved mismatch | Go ABI0 treats **all** registers as scratch; this code clobbers `rbx` (XOR, GCM), `rbp` (ChaCha uses BP as a data pointer), `r12–r15` (P-256). SysV requires `rbx, rbp, r12–r15` preserved | shim pushes/pops whichever of those the body touches (or all six) |
| Stack-split prologue | non-`NOSPLIT` TEXT with a frame → TLS `g` load + `runtime.morestack_noctxt` call injected at assembly time | add `NOSPLIT` to the `TEXT` line before assembling; frames here are ≤680 B |
| Constant tables | `DATA`/`GLOBL` become local rodata symbols referenced via `R_PCREL`; unlinked-object bytes have zeroed displacements | emit rodata + labels and let the system assembler relocate (Strategy 3) |
| Stack red zone / alignment | ABI0 doesn't keep 16-byte alignment; SysV leaf code may rely on the 128-byte red zone Go doesn't have | these bodies use unaligned SSE loads and own their frame — fine; align in the shim if you add calls |
| CET/BTI hardening | extracted code has no `endbr64` / BTI landing pads | put `endbr64` in the shim only; body is reached by direct call |
| arm64 differences | `g` lives in `R28`, `R27` is the assembler temp; AAPCS64 wants `x19–x28` preserved and Go clobbers them freely | same shim idea, bigger save set; Go's arm64 spelling is closer to standard but operand order still differs |
| Licensing | Go's BSD-3 + PATENTS; some files carry CloudFlare/Intel provenance headers | keep the headers in whatever you generate |

Constant-time behavior survives extraction by construction — the instruction
bytes are identical to what Go executes.

## What does *not* work / anti-options

- Linking the `go tool asm` `.o` into Rust directly: goobj, not ELF.
- `go build -buildmode=c-archive`: gives you a linkable ELF archive, but it
  drags the entire Go runtime and its signal handlers into your Rust process;
  you get the Go *functions*, not reusable assembly.
- `objcopy`-ing functions out of a linked Go binary: constant references are
  `%rip`-relative to sections placed far away; the bytes don't relocate.

## Prior art

- [rustgo](https://words.filippo.io/rustgo/) — Filippo Valsorda's
  trampoline for calling Rust from Go; the shim in `demo/goxor.S` is the same
  idea pointed the other way.
- [Rust2Go part 2](https://en.ihcblog.com/rust2go-cgo-asm/) — asm-level
  Rust⇄Go calls, ABI-bridging tricks.
- [c2goasm](https://github.com/minio/c2goasm), [gocc](https://github.com/kelindar/gocc),
  avo — the reverse (into Go asm) toolchain; useful as design references for a
  Plan9→GAS translator.
- [A Quick Guide to Go's Assembler](https://go.dev/doc/asm) — the semantics of
  `FP`/`SB`/`SP`, `NOSPLIT`, `DATA`/`GLOBL`.
- [Go Wiki: GcToolchainTricks](https://go.dev/wiki/GcToolchainTricks).

## Recommendation

For crypto/tls-grade primitives, use Strategy 1: take the perlasm/upstream
twins that *ring*/aws-lc-rs already build, rather than laundering the Go
copies backwards. Reach for Strategy 2 when a routine exists *only* as Go
assembly and is a self-contained leaf (several `math/big` kernels and the
hash block functions qualify). Budget Strategy 3 only if you need the
constant-bearing AEAD/EC bodies byte-for-byte as Go ships them.
