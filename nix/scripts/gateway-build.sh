#!/bin/sh
set -e

log_step() {
  if [ "${OPENCLAW_NIX_TIMINGS:-1}" != "1" ]; then
    "$@"
    return
  fi

  name="$1"
  shift

  start=$(date +%s)
  printf '>> [timing] %s...\n' "$name" >&2
  "$@"
  end=$(date +%s)
  printf '>> [timing] %s: %ss\n' "$name" "$((end - start))" >&2
}

if [ -z "${GATEWAY_PREBUILD_SH:-}" ]; then
  echo "GATEWAY_PREBUILD_SH is not set" >&2
  exit 1
fi
. "$GATEWAY_PREBUILD_SH"
if [ -z "${STDENV_SETUP:-}" ]; then
  echo "STDENV_SETUP is not set" >&2
  exit 1
fi
if [ ! -f "$STDENV_SETUP" ]; then
  echo "STDENV_SETUP not found: $STDENV_SETUP" >&2
  exit 1
fi

store_path_file="${PNPM_STORE_PATH_FILE:-.pnpm-store-path}"
if [ ! -f "$store_path_file" ]; then
  echo "pnpm store path file missing: $store_path_file" >&2
  exit 1
fi
store_path="$(cat "$store_path_file")"
export PNPM_STORE_DIR="$store_path"
export PNPM_STORE_PATH="$store_path"
export NPM_CONFIG_STORE_DIR="$store_path"
export NPM_CONFIG_STORE_PATH="$store_path"
export HOME="$(mktemp -d)"

log_step "pnpm install (offline, frozen, ignore-scripts)" pnpm install --offline --frozen-lockfile --ignore-scripts --store-dir "$store_path"

log_step "chmod node_modules writable" chmod -R u+w node_modules

# sharp may leave build artifacts around; remove to keep output smaller + avoid stale builds.
rm -rf node_modules/.pnpm/sharp@*/node_modules/sharp/src/build

# Rebuild only native deps (avoid `pnpm rebuild` over the entire workspace).
# node-llama-cpp postinstall attempts to download/compile llama.cpp (network blocked in Nix).
# Also defensively disable other common downloaders.
rebuild_list="sharp"
log_step "pnpm rebuild (native deps)" env \
  NODE_LLAMA_CPP_SKIP_DOWNLOAD=1 \
  PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
  PUPPETEER_SKIP_DOWNLOAD=1 \
  ELECTRON_SKIP_BINARY_DOWNLOAD=1 \
  pnpm rebuild $rebuild_list

log_step "patchShebangs node_modules/.bin" bash -e -c ". \"$STDENV_SETUP\"; patchShebangs node_modules/.bin"

# Ensure rolldown is found from workspace bins in offline/sandbox builds.
if [ -d "node_modules/.pnpm/node_modules/.bin" ]; then
  export PATH="$PWD/node_modules/.pnpm/node_modules/.bin:$PATH"
fi

# Break down `pnpm build` (upstream package.json) so we can profile it.
log_step "build: plugins:assets:build" pnpm plugins:assets:build
log_step "build: canvas:a2ui:bundle" pnpm canvas:a2ui:bundle
log_step "build: tsdown" node scripts/tsdown-build.mjs
log_step "build: check-cli-bootstrap-imports" node scripts/check-cli-bootstrap-imports.mjs
log_step "build: runtime-postbuild" node scripts/runtime-postbuild.mjs
log_step "build: build-stamp" node scripts/build-stamp.mjs
log_step "build: runtime-postbuild-stamp" node scripts/runtime-postbuild-stamp.mjs
log_step "build: plugin-sdk dts" pnpm build:plugin-sdk:dts
log_step "build: write-plugin-sdk-entry-dts" node --import tsx scripts/write-plugin-sdk-entry-dts.ts
log_step "build: check-plugin-sdk-exports" node scripts/check-plugin-sdk-exports.mjs
log_step "build: plugins:assets:copy" pnpm plugins:assets:copy
log_step "build: copy-hook-metadata" node --import tsx scripts/copy-hook-metadata.ts
log_step "build: copy-export-html-templates" node --import tsx scripts/copy-export-html-templates.ts
log_step "build: write-build-info" node --import tsx scripts/write-build-info.ts
log_step "build: write-cli-startup-metadata" node --import tsx scripts/write-cli-startup-metadata.ts
log_step "build: write-cli-compat" node --import tsx scripts/write-cli-compat.ts

log_step "ui:build" pnpm ui:build

log_step "pnpm prune --prod" env CI=true pnpm prune --prod

# Reduce output size (pnpm implementation detail; safe to remove)
rm -rf node_modules/.pnpm/node_modules
