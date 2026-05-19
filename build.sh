#!/usr/bin/env bash
# Build zcc: a model-agnostic coding agent written in the Zero language.
#
# The Zero "direct" backend emits a relocatable object; this script links
# it against the small vendored C runtime (+ libcurl) to produce ./build/zcc.
#
# Requirements: git, a C compiler (cc/gcc/clang), make, and libcurl.
#   Debian/Ubuntu:  apt-get install -y build-essential git libcurl4-openssl-dev
#   Fedora:         dnf install -y gcc make git libcurl-devel
#   macOS:          xcode-select --install   (libcurl ships with the SDK)
#
# Override the compiler with ZERO=/path/to/zero if you already have a
# from-source build of github.com/vercel-labs/zero.

set -euo pipefail
cd "$(dirname "$0")"

CC="${CC:-cc}"
ZERO_REPO="${ZERO_REPO:-https://github.com/vercel-labs/zero.git}"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-.toolchain/zero}"

# ---- 1. obtain a from-source Zero compiler -------------------------------
# (The released prebuilt binary predates the syntax/backend this uses, so
#  we build the compiler from source. It is plain C; `make` is enough.)
if [ -n "${ZERO:-}" ] && [ -x "${ZERO}" ]; then
  ZBIN="${ZERO}"
else
  if [ ! -x "${TOOLCHAIN_DIR}/.zero/bin/zero" ]; then
    echo ">> fetching Zero compiler ..."
    rm -rf "${TOOLCHAIN_DIR}"
    git clone --depth 1 "${ZERO_REPO}" "${TOOLCHAIN_DIR}"
    echo ">> building Zero compiler ..."
    make -C "${TOOLCHAIN_DIR}/native/zero-c"
  fi
  ZBIN="${TOOLCHAIN_DIR}/.zero/bin/zero"
fi
echo ">> using zero: ${ZBIN}"
"${ZBIN}" --version | head -1

# ---- 2. compile zcc to an object ----------------------------------------
mkdir -p build
echo ">> compiling src/main.0 ..."
ZERO_CC="${CC}" "${ZBIN}" build --emit obj --target linux-x64 zero.json --out build/zcc.o

# ---- 3. link with the vendored runtime + libcurl ------------------------
link() { $CC -O2 -s -Iruntime/include -Ivendor/curl-include \
  build/zcc.o runtime/zero_runtime.c runtime/zero_http_curl.c "$@" \
  -o build/zcc; }

echo ">> linking ..."
if link -lcurl 2>/dev/null; then :
elif link -l:libcurl.so.4 2>/dev/null; then :
elif command -v pkg-config >/dev/null && pkg-config --exists libcurl; then
  link $(pkg-config --libs libcurl)
else
  echo "!! could not link libcurl. Install libcurl dev headers/lib." >&2
  echo "   Debian/Ubuntu: apt-get install -y libcurl4-openssl-dev" >&2
  exit 1
fi

echo ">> built: ./build/zcc"
./build/zcc 2>&1 | head -1 || true
