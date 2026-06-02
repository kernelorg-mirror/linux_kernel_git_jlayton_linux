#!/usr/bin/env bash
set -ex

cd "$(buck2 root)" || (echo "build command must run from the linux tree" && exit 1)

repo_root="$(buck root)"
# If no arguments provided default to the :x86_64 target
args="${@:-":x86_64"}"
buck2 build $("$repo_root/facebook/build/buck-config") $args
