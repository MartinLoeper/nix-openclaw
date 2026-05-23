{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchurl,
  nodejs_22,
  pnpm_10,
  fetchPnpmDeps,
  pkg-config,
  jq,
  python3,
  node-gyp,
  git,
  zstd,
  yq,
}:

# Shared build plumbing for OpenClaw gateway-related derivations.
#
# Goals:
# - one source of truth for pnpm deps fetch + common env
# - keep the individual derivations small/boring

{
  pname,
  sourceInfo,
  pnpmDepsHash ? (sourceInfo.pnpmDepsHash or null),
  pnpmDepsPname ? "openclaw-gateway",
  gatewaySrc ? null,
  src ? null,
  enableSharp ? false,
  extraNativeBuildInputs ? [ ],
  extraBuildInputs ? [ ],
  extraEnv ? { },
}:

let
  sourceFetch = lib.removeAttrs sourceInfo [ "pnpmDepsHash" ];

  # Prefer nixpkgs' platform mapping instead of hand-rolled arch/platform.
  pnpmPlatform = stdenv.hostPlatform.node.platform;
  pnpmArch = stdenv.hostPlatform.node.arch;

  revShort = lib.substring 0 8 sourceInfo.rev;
  version = "unstable-${revShort}";

  resolvedSrc =
    if src != null then
      src
    else if gatewaySrc != null then
      gatewaySrc
    else
      fetchFromGitHub sourceFetch;

  nodeAddonApi = import ../packages/node-addon-api.nix { inherit stdenv fetchurl; };

  pnpmDeps = fetchPnpmDeps {
    pname = pnpmDepsPname;
    inherit version;
    src = resolvedSrc;
    pnpm = pnpm_10;
    hash = if pnpmDepsHash != null then pnpmDepsHash else lib.fakeHash;
    fetcherVersion = 3;
    npm_config_arch = pnpmArch;
    npm_config_platform = pnpmPlatform;
    nativeBuildInputs = [ git python3 yq ];
    prePnpmInstall = ''
      python3 - <<'PY'
import json
import subprocess
from pathlib import Path

workspace = Path("pnpm-workspace.yaml")
lockfile = Path("pnpm-lock.yaml")
workspace_json = json.loads(subprocess.check_output(["yq", ".", str(workspace)]))
lockfile_json = json.loads(subprocess.check_output(["yq", ".", str(lockfile)]))
workspace_patches = workspace_json.get("patchedDependencies", {})
lockfile_patches = lockfile_json.get("patchedDependencies", {})

merged_patches = {}
for name, patch_path in workspace_patches.items():
    lockfile_patch = lockfile_patches.get(name)
    if isinstance(lockfile_patch, dict):
        patch_hash = lockfile_patch.get("hash")
    else:
        patch_hash = lockfile_patch
    merged_patches[name] = {"hash": patch_hash, "path": patch_path}

if merged_patches:
    lockfile_json["patchedDependencies"] = merged_patches
    lockfile.write_text(subprocess.check_output(["yq", "-y", "."], input=json.dumps(lockfile_json).encode()).decode())
PY
    '';
  };

  envBase = {
    npm_config_arch = pnpmArch;
    npm_config_platform = pnpmPlatform;
    PNPM_CONFIG_MANAGE_PACKAGE_MANAGER_VERSIONS = "false";
    npm_config_nodedir = nodejs_22;
    npm_config_python = python3;
    NODE_PATH = "${nodeAddonApi}/lib/node_modules:${node-gyp}/lib/node_modules";
    PNPM_DEPS = pnpmDeps;
    NODE_GYP_WRAPPER_SH = "${../scripts/node-gyp-wrapper.sh}";
    GATEWAY_PREBUILD_SH = "${../scripts/gateway-prebuild.sh}";
    PROMOTE_PNPM_INTEGRITY_SH = "${../scripts/promote-pnpm-integrity.sh}";
    REMOVE_PACKAGE_MANAGER_FIELD_SH = "${../scripts/remove-package-manager-field.sh}";
    STDENV_SETUP = "${stdenv}/setup";
  };

in
{
  inherit
    version
    pnpmDeps
    resolvedSrc
    pnpmPlatform
    pnpmArch
    nodeAddonApi
    ;

  nativeBuildInputs = [
    nodejs_22
    pnpm_10
    pkg-config
    jq
    python3
    node-gyp
    zstd
    yq
  ]
  ++ extraNativeBuildInputs;

  buildInputs = extraBuildInputs;

  env = envBase // (lib.optionalAttrs enableSharp { SHARP_IGNORE_GLOBAL_LIBVIPS = "1"; }) // extraEnv;

  passthru = {
    inherit sourceInfo pnpmDeps;
    pinnedRev = sourceInfo.rev;
  };
}
