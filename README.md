# zcc — a model-agnostic Claude-Code-style coding agent, written in Zero

`zcc` is a small autonomous coding agent built in
[Zero](https://zerolang.ai) (`github.com/vercel-labs/zero`), the
agent-first experimental language. It talks to **any** LLM behind an
Anthropic Messages or OpenAI-compatible Chat Completions endpoint, is
handed a set of workspace files, performs a task, and rewrites those
files in place — like a one-shot Claude Code that you point at any model.

The design borrows the spirit of Claude Code / `ccunpacked.dev`: a
terse senior-engineer system prompt, a tight tool loop, whole-file
rewrites, and a strict machine-parseable protocol — re-implemented
within what the Zero toolchain can actually compile today.

## What it does

```
zcc "add input validation and tests"  src/api.py  tests/test_api.py
zcc -f TASK.md  src/server.ts  src/router.ts  README.md
```

1. Reads every workspace file you pass as an argument.
2. Sends them, plus your task and a coding system prompt, to your model.
3. Streams the model's reply to stdout.
4. Applies every `@@WRITE <path> … @@END` block the model emits,
   writing the new contents back to disk (only paths you passed are
   writable — the agent cannot touch anything else).

The exact request/response is saved to `.zcc/last-request.txt` and
`.zcc/last-response.txt` for debugging.

## Model-agnostic configuration

All configuration is environment variables:

| Var | Meaning | Default |
|-----|---------|---------|
| `ZCC_API` | `anthropic` or `openai` | `anthropic` |
| `ZCC_BASE_URL` | API origin | `https://api.anthropic.com` / `https://api.openai.com` |
| `ZCC_MODEL` | model id (**required**) | — |
| `ZCC_KEY` | API key (or `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`) | — |
| `ZCC_MAX_TOKENS` | max output tokens | `4096` |

`ZCC_API=openai` speaks the OpenAI Chat Completions wire format, which
nearly everything implements:

```sh
# Anthropic
ZCC_API=anthropic ZCC_MODEL=claude-sonnet-4-5 ANTHROPIC_API_KEY=sk-ant-... \
  zcc "refactor for clarity" src/main.rs

# OpenAI
ZCC_API=openai ZCC_MODEL=gpt-4o OPENAI_API_KEY=sk-... \
  zcc "fix the failing edge case" app/handler.go

# OpenRouter / Groq / DeepSeek / Together / Mistral (OpenAI-compatible)
ZCC_API=openai ZCC_BASE_URL=https://openrouter.ai/api ZCC_MODEL=anthropic/claude-sonnet-4-5 \
  ZCC_KEY=sk-or-... zcc "add docstrings" lib/util.py

# Local: Ollama / llama.cpp / vLLM
ZCC_API=openai ZCC_BASE_URL=http://localhost:11434 ZCC_MODEL=qwen2.5-coder \
  ZCC_KEY=x zcc "write unit tests" calc.js
```

## Build

```sh
./build.sh        # produces ./build/zcc
```

`build.sh` fetches and builds the Zero compiler from source (it is plain
C — just `make`), compiles `src/main.0` to an object with the Zero
direct backend, and links it against the vendored C runtime and
`libcurl`. Needs `git`, `cc`, `make`, and libcurl
(`apt-get install -y libcurl4-openssl-dev`, `dnf install libcurl-devel`,
or the macOS SDK). Set `ZERO=/path/to/zero` to reuse an existing
from-source compiler.

## The agent protocol

The model is instructed to reply with optional brief reasoning, then,
for each changed file:

```
@@WRITE relative/path.ext
<the complete new file contents>
@@END
```

and to finish with `@@DONE <summary>`. `zcc` parses these blocks and
writes each file whose path byte-exactly matches one of the workspace
arguments.

## Honest scope & why it is shaped this way

Zero is a pre-1.0 experiment and its shipping toolchain constrains what
is buildable. `zcc` is built strictly within that envelope:

- **No interactive REPL.** Zero exposes no stdin capability, so `zcc` is
  invocation-scoped. Multi-turn = run it again; the prior exchange is in
  `.zcc/`.
- **No shell tool.** `std.proc` only returns an exit code (no argv, no
  output capture), so there is no `bash` tool. The agent works through
  whole-file rewrites of the files you explicitly pass — which keeps it
  sandboxed by construction.
- **Writes are allowlisted.** The agent can only write paths you passed
  on the command line; invented paths are ignored.
- **Fixed buffers.** The Zero direct backend emits per-element array
  initialisation, so buffers are compile-time fixed (and kept modest to
  keep the binary small). Tune the `[N]u8` / `*cap` constants at the top
  of `src/main.0` if you need larger files or responses, then rebuild.
- **`\uXXXX`** in model output is replaced with `?` (rare in code).

Everything else — model-agnostic HTTPS calls (real TLS via libcurl),
JSON request building with proper escaping, response parsing, and
multi-file in-place edits — works end to end.

## Layout

```
src/main.0              the whole agent (one inlined routine — the Zero
                        direct backend forbids user fns over spans)
runtime/                vendored Zero C runtime (Apache-2.0)
vendor/curl-include/    curl headers for linking libcurl (curl license)
build.sh                fetch compiler + compile + link
THIRD_PARTY_LICENSES/   upstream licenses
```

## Licenses

`zcc` is MIT (see `LICENSE`). It vendors the Zero runtime
(Apache-2.0) and curl headers (curl license); see
`THIRD_PARTY_LICENSES/`.
