#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$root"

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: Rust/Cargo is required to build simpleplug-daemon" >&2
  exit 1
fi

cargo build --release --locked
mkdir -p lib
install -m 755 target/release/simpleplug-daemon lib/simpleplug-daemon

echo "Installed to $root/lib/simpleplug-daemon"
