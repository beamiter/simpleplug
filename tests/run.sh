#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

cargo fmt -- --check
cargo test
vim -Nu NONE -i NONE -n -es -S tests/vim_smoke.vim
