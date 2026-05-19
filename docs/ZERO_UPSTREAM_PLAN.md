# Zero upstream plan & spec — unblocking real agent programs

Status: proposal for a feature branch against `github.com/vercel-labs/zero`
Author context: written after building `zcc` (a model-agnostic coding
agent) entirely in Zero. Every item below is a concrete blocker that
forced a workaround in `src/main.0`; each is reproducible with the
from-source compiler (`make -C native/zero-c`).

The north star: **`zcc` should be rewritable idiomatically** — with
functions, dynamic file paths, a real process tool, JSON accessors,
normal buffer sizes, and a small binary. Each section ends with the
acceptance test that proves that blocker is gone.

Repo map (native compiler, all C):
`native/zero-c/src/{lexer,parser,checker,ir,target,fs,main}.c`,
`native/zero-c/src/emit_{elf64,elf_aarch64,macho64,coff,wasm}.c`,
`native/zero-c/runtime/{zero_runtime,zero_http_curl}.c`,
`native/zero-c/include/{zero,zero_runtime}.h`,
`native/zero-c/targets/targets.manifest`,
`conformance/native/{pass,fail}/*.0`, `conformance/run.mjs`,
`scripts/zero-cli.mjs` (node driver behind `bin/zero`),
`docs-site/articles/modules/*.md`.

---

## P0-1 — Aggregate/reference parameter ABI in the direct backend

**The single biggest blocker.** User-defined functions whose parameters
are `Span<u8>`, `MutSpan<u8>`, `String`, `Maybe<T>`, or shapes are
rejected by the direct ELF64 backend; the entire agent had to be
inlined into `main`.

Evidence:
```
./src/main.0:28:16 CGEN004: direct backend parameter type is unsupported
  expected: direct ELF64 object MVP subset
  actual: MutSpan<u8>
```
Control: a function with only primitive params compiles to an 880-byte
object. So the gate is specifically aggregate/reference parameter types.

Root cause: `emit_elf64.c` (and the AArch64/COFF emitters) implement a
"primitive integer arithmetic" calling convention only; `checker.c`
raises `CGEN004` when a user function signature contains a non-primitive
parameter/return.

### Proposed ABI (System V AMD64-flavoured, mirror per backend)

Define lowered representations in `ir.c` and one calling convention in
each emitter:

| Zero type | Lowered representation | Passing |
|---|---|---|
| `iN`/`uN`/`usize`/`Bool`/`char` | scalar | 1 integer reg / stack slot |
| `Span<T>` / `MutSpan<T>` / `String` | fat pointer `{ ptr: *T, len: usize }` | 2 integer regs (`ptr`,`len`) or 16-byte stack pair |
| `ref<T>` / `mutref<T>` / `owned<T>` | thin pointer `*T` | 1 integer reg |
| `Maybe<T>` | `{ has: u8, value: T }` | `T`-sized+1 by value if ≤ 16 bytes else hidden pointer |
| `shape` (≤ 16 bytes, all-scalar) | by value, field-flattened to ≤ 2 regs | regs |
| `shape` (> 16 bytes) | hidden caller-allocated pointer (sret for returns) | pointer |

Rules:
- Return values follow the same classification; aggregates > 16 bytes
  use an sret hidden first parameter.
- Borrow checker semantics are unchanged; this is purely lowering.
- `MutSpan`/`mutref` keep their existing writability checks.

### Work items
1. `ir.c`: add an ABI classification pass (`zero_abi_classify(type)` →
   {SCALAR, FATPTR, PTR, MAYBE, AGG_REGS, AGG_MEM}).
2. `emit_elf64.c`: implement argument marshalling/return for each class;
   replace the `CGEN004` parameter rejection with real codegen. Repeat
   for `emit_elf_aarch64.c`, `emit_macho64.c`, `emit_coff.c` (AAPCS64 /
   Win x64 variants).
3. `checker.c`: drop the "primitive-only" parameter gate for direct
   targets; keep genuine "unsupported on target X" diagnostics.
4. `abi check`/`abi dump` (already a CLI verb) must report the new
   classification.

### Acceptance
- New fixtures `conformance/native/pass/abi-fatptr-params.0`,
  `abi-maybe-return.0`, `abi-shape-byval.0`, `abi-sret.0` build with
  `--emit obj --target linux-x64`, link, and run.
- `zcc` refactored so `appendByte`, `appendSpan`, `appendEsc`,
  `findSub`, `jsonUnescape`, `envOr` are real functions again; binary
  behaviour identical.

---

## P0-2 — Array zero-initialisation must not emit O(N) code

`let mut a: [N]u8 = [0_u8; N]` emits one store per element. Measured
object/binary sizes (linear, ≈ 40 bytes per array byte):

| N | object | linked binary |
|---|---|---|
| 4 096 | 164 KB | 181 KB |
| 65 536 | 2.62 MB | 2.64 MB |
| 1 048 576 | 41.9 MB | 41.96 MB |

`zcc` had to shrink every buffer; even so the binary is 16 MB. A 1 MB
HTTP response buffer is infeasible today.

Root cause: `emit_elf64.c` lowers the repeat-literal as N immediate
stores instead of placing zeroed aggregates in `.bss` or emitting a
counted clear.

### Proposed change
- Recognise "all-zero constant initializer" (`[0_x; N]`, zeroed shapes)
  in `ir.c`; place such locals/globals in `.bss` (loader-zeroed) or, for
  stack locals, emit a single `zero_memset(ptr, 0, n)` runtime call
  (add `zero_memset`/`zero_memcpy` to `runtime/zero_runtime.c`).
- Non-zero small repeats (`[7_u8; 16]`): bounded loop, not unrolled
  beyond a threshold (e.g. 32).
- Large non-zero repeats: counted loop using the runtime helper.

### Acceptance
- New `conformance/native/pass/array-zeroinit-bss.0` with a
  `[1048576]u8` buffer; assert via `zero size --json` that
  `.text` growth is O(1) and the linked binary is < 256 KB.
- `zcc` buffers restored to realistic sizes (e.g. 1 MB request /
  response) with a binary < 1 MB.

---

## P0-3 — `zero run` and `--emit exe` must drive the host runtime link

On the host (`linux-x64`) any stdlib-using program fails:
```
zero run src/main.0
CGEN004: direct backend does not support target 'linux-x64' for --emit exe
```
Yet `zero build --emit obj --target linux-x64 … && cc obj zero_runtime.c
zero_http_curl.c -lcurl` works perfectly (this is exactly how `zcc` is
built). And `zero build --emit exe --target linux-x64` already works for
`json`/`mem` programs (`runtimeHelperCount:1`) but rejects `fs`/`proc`/
`net` programs.

Root cause: the `run`/`--emit exe` host path selects the bare direct-exe
emitter (no libc/runtime link) instead of the obj→`cc`-link plan; and
the link plan that exists only covers a one-helper subset.

### Proposed change
In the driver (`scripts/zero-cli.mjs` host path and/or `src/main.c` +
`src/fs.c` `z_run_cc`/link-plan):
1. For host executable output, always: emit obj → compile
   `zero_runtime.c` (+ `zero_http_curl.c` when `net` used) with
   `ZERO_CC` → link with `cc` → (for `run`) exec in a temp dir, exit
   with the child's status.
2. Generalise the runtime-helper accounting so `fs`/`proc`/`net`/`time`/
   `rand` helper sets are all linkable, and add `-lcurl` to the link
   plan when the program uses `net`.
3. Keep the bare direct-exe emitter for freestanding/no-runtime
   programs (e.g. `hello.0`) as a fast path.

### Acceptance
- `zero run conformance/native/pass/std-fs.0`,
  `… std-platform-basics.0`, and a real `std.http.fetch` program all
  run on host with no manual `cc` step.
- `zero build --emit exe --target linux-x64` produces a runnable
  binary for fs/proc/net programs.

---

## P0-4 — Real process API (`std.proc`)

`std.proc.spawn(cmd)` returns only an exit code, does **not** run a
shell, takes no argv, and captures no output. Verified:
`spawn("sh -c 'echo hi > /tmp/x'")` returned exit 0 but created no file.
This makes a `bash`/run tool impossible; `zcc` has no shell tool at all.

### Proposed API (`docs-site/articles/modules/proc.md` + runtime)
```
std.proc.run(
    argv: Span<String>,            // argv[0] = program
    stdin: Span<u8>,               // bytes piped to child (may be empty)
    out: MutSpan<u8>,              // child stdout captured here
    err: MutSpan<u8>,              // child stderr captured here
    timeout: Duration
) -> ProcResult
std.proc.exitCode(r) -> i32
std.proc.outLen(r) -> usize
std.proc.errLen(r) -> usize
std.proc.timedOut(r) -> Bool
```
Host runtime (`runtime/zero_runtime.c`): `posix_spawn`/`fork`+`execvp`
with three pipes, non-blocking drain into caller buffers, `SIGKILL` on
timeout. Capability `proc`; non-host targets reject as today. No shell
interpretation (argv vector, not a string) — safe by construction.

### Acceptance
- `conformance/native/pass/std-proc-run.0`: run `/bin/echo hi`, assert
  stdout == `hi\n`, exit 0; run a failing command, assert non-zero.
- `zcc` gains a real `run` tool surfaced to the model.

---

## P0-5 — JSON accessor API

`std.json.parseBytes` returns an opaque `JsonDoc`; there is no way to
read a field/element/value (confirmed in `modules/json.md`). `zcc`
hand-rolls byte scanning + unescaping and uses a sentinel tool protocol
because provider JSON cannot be navigated.

### Proposed API
```
std.json.kind(node) -> JsonKind            // object|array|string|number|bool|null
std.json.get(node, key: Span<u8>) -> Maybe<JsonNode>
std.json.at(node, index: usize) -> Maybe<JsonNode>
std.json.len(node) -> usize                // array/object size
std.json.string(node, out: MutSpan<u8>) -> Maybe<usize>   // unescaped
std.json.int(node) -> Maybe<i64>
std.json.float(node) -> Maybe<f64>
std.json.bool(node) -> Maybe<Bool>
std.json.root(doc) -> JsonNode
```
The parser already builds an arena-backed tree; expose typed navigation
over it (string decode writes unescaped UTF-8, including `\uXXXX` +
surrogate pairs, into caller storage).

### Acceptance
- `conformance/native/pass/std-json-nav.0`: parse
  `{"choices":[{"message":{"content":"hi\n"}}]}`, extract
  `content` == `hi\n`.
- `zcc` parses provider responses with the accessor API (still keeps the
  sentinel protocol for tool calls — that is a deliberate design choice,
  not a workaround).

---

## P1-6 — Bitwise operators

`|  &  ^  <<  >>  ~` are not lexed:
```
src/main.0:122:41 PAR100: unexpected character '|'
t_bit.0:1:70   PAR100: unexpected character '~'
```
This blocked the UTF-8/`\u` decoder (had to emit `?`) and rules out
hashing, bit flags, and binary codecs.

### Work items
- `lexer.c`: tokens `|`, `&`, `^`, `<<`, `>>`, `~` (and `|=`… optional).
- `parser.c`: precedence (C-like: `<<`/`>>` above `&`, then `^`, then
  `|`, all below comparisons; `~` unary with `-`).
- `checker.c`: integer-only operands, no implicit width/sign change,
  result type = operand type; constant-fold in the compile-time
  evaluator.
- `ir.c` + every emitter: shift/mask/xor/not opcodes; shift-amount
  masked to operand width; document `>>` as logical for unsigned,
  arithmetic for signed.

### Acceptance
- `conformance/native/pass/ops-bitwise.0` covering each operator and
  precedence; `zcc` decodes `\uXXXX` (incl. surrogate pairs) to real
  UTF-8.

(Note: `* / %` already work — verified — so no arithmetic work is
needed; only bitwise.)

---

## P1-7 — `Span<u8>` / bytes → `String`, or `Span<u8>` paths in `std.fs`

`std.fs.*` take `String` paths. Model-produced path bytes can't become a
`String` (no constructor), so dynamic file targets are impossible —
`zcc` only writes paths passed on argv.

### Proposed change (pick the smaller one)
- Preferred: accept `Span<u8>` wherever a path `String` is accepted
  (`String` already lowers to `{ptr,len}`; `fs.c` can take ptr/len
  directly). One `checker.c` overload rule + signature widening in
  `modules/fs.md`.
- Or: add `std.str.fromBytes(Span<u8>) -> String` (borrowed view; no
  copy, no NUL guarantee — document that fs makes its own NUL-terminated
  copy).

### Acceptance
- `conformance/native/pass/fs-span-path.0`: build a path in a buffer,
  `std.fs.writeBytes(pathSpan, …)`, read it back.
- `zcc` lets the model name any path (still allowlisted by policy, but
  not by language limitation).

---

## P1-8 — Stdin / interactive input capability

`World` exposes `out`/`err` only; `std.io` is caller-buffer plumbing
with no process input. No REPL is possible, so `zcc` is invocation-only.

### Proposed API
```
world.in.read(buf: MutSpan<u8>) -> usize        // 0 = EOF
std.io.readLine(world, buf: MutSpan<u8>) -> Maybe<usize>
```
Runtime: add `zero_world_read(fd, buf, len)` to `zero_runtime.c`
(mirror of `zero_world_write`). New target capability `stdin`
(host/wasi yes; browser-worker no) in `targets.manifest` + `target.c`.

### Acceptance
- `conformance/native/pass/world-stdin.0`: echo a piped line.
- `zcc` gains an interactive multi-turn REPL mode.

---

## P2-9 — `else if` chaining

```
if x==1 {…} else if x==3 {…} else {…}
PAR100: expected '}' after block
```
Forces deeply nested `else { if … }`. `parser.c`: after `else`, allow an
`if` statement (not only a block). Pure parser change; no codegen
impact. Acceptance: `conformance/native/pass/else-if-chain.0`; `zcc`
escaper/unescaper de-nested.

---

## P2-10 — Release & version hygiene (process, not code)

The published `install.sh` binary predates repo HEAD: it rejects the
`[0_u8; N]` repeat literal that shipped examples use, and `zero
--version` prints `commit: unknown`, `target compiler: missing` even on
a healthy from-source build.

- Stamp the git commit into the binary at `make` time (CI release).
- Cut releases from the same tree as docs/examples (conformance gate).
- Reword/repair the `target compiler: missing` line (it means "no cross
  C toolchain"); detect host `cc` and say so.

Acceptance: a freshly installed binary compiles `examples/*.0` and the
conformance suite without syntax skew.

---

## P2-11 — Don't silently stub HTTP when libcurl headers are absent

`zero_http_curl.c` enables curl only under
`__has_include(<curl/curl.h>)`. With no curl dev headers the file
compiles to a **no-op stub** and `std.http.fetch` silently fails — a
program "builds" but networking is dead (this cost real debugging time;
`zcc` vendors curl headers to dodge it).

### Proposed change
When the program uses the `net` capability and the link plan can't find
curl headers/lib, emit a hard diagnostic (e.g. `BLD0xx: net capability
requires libcurl development files`), not a silent stub. Optionally
vendor a minimal pinned `curl.h` subset, or `dlopen` libcurl at runtime.
Surface this in `zero targets --json` `httpRuntime` facts.

Acceptance: building a `net` program without libcurl fails loudly with
remediation text; with libcurl it works (unchanged).

---

## Sequencing / PR plan

Branch `feat/agent-ready` off `main`; land as a stack of reviewable PRs:

1. **PR1 P0-2** array `.bss` zero-init (small, high ROI, unblocks size).
2. **PR2 P0-1** aggregate/reference parameter ABI (largest; gated by
   conformance fixtures; do x86-64 first, then AArch64/COFF).
3. **PR3 P0-3** host run/exe runtime-link generalisation.
4. **PR4 P1-6** bitwise operators.
5. **PR5 P0-4** real `std.proc.run`.
6. **PR6 P0-5** JSON accessors.
7. **PR7 P1-7** span/bytes paths; **PR8 P1-8** stdin; **PR9 P2-9**
   `else if`; **PR10 P2-10/11** release & curl hygiene.

Each PR: code + `conformance/native/pass` (and `fail`) fixtures +
`docs-site/articles/modules/*` updates + a `CHANGELOG` entry. Gate with
`npm run conformance` and `npm run native:test`.

## Definition of done

`zcc` is rewritten idiomatically: real helper functions; realistic 1 MB
buffers with a sub-1 MB binary; `zero run src/main.0` works with no
manual `cc`; a real `run` tool; JSON parsed via accessors; dynamic
paths; optional interactive REPL. The `zcc` diff that accompanies the
final PR is the end-to-end proof.
