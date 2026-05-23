{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchurl,
  nodejs_22,
  pnpm_10,
  fetchPnpmDeps,
  bun,
  pkg-config,
  jq,
  python3,
  node-gyp,
  vips,
  git,
  zstd,
  yq,
  sourceInfo,
  pnpmDepsHash ? (sourceInfo.pnpmDepsHash or null),
}:

let
  common =
    import ../lib/openclaw-gateway-common.nix
      {
        inherit
          lib
          stdenv
          fetchFromGitHub
          fetchurl
          nodejs_22
          pnpm_10
          fetchPnpmDeps
          pkg-config
          jq
          python3
          node-gyp
          git
          zstd
          yq
          ;
      }
      {
        pname = "openclaw-gateway-tests";
        sourceInfo = sourceInfo;
        pnpmDepsHash = pnpmDepsHash;
        pnpmDepsPname = "openclaw-gateway";
        enableSharp = true;
        extraNativeBuildInputs = [ bun ];
        extraBuildInputs = [ vips ];
      };

in

stdenv.mkDerivation (finalAttrs: {
  pname = "openclaw-gateway-tests";
  inherit (common) version;

  src = common.resolvedSrc;
  pnpmDeps = common.pnpmDeps;

  nativeBuildInputs = common.nativeBuildInputs;
  buildInputs = common.buildInputs;

  env = common.env // {
    PNPM_DEPS = finalAttrs.pnpmDeps;
  };

  passthru = common.passthru;

  postPatch = "${../scripts/gateway-postpatch.sh}";
  buildPhase = "${../scripts/gateway-tests-build.sh}";

  doCheck = true;
  checkPhase = "${../scripts/gateway-tests-check.sh}";

  installPhase = "${../scripts/empty-install.sh}";
  dontPatchShebangs = true;
})
