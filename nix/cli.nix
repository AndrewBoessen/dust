{ lib
, beamPackages
, makeWrapper
}:

# Builds `dustctl` as a plain mix release. Burrito (used for the
# GitHub-released self-contained binaries) is stripped via the patch
# under `nix/patches/` so we don't need Zig/7z in the sandbox and so the
# release isn't an opaque self-extracting blob.
let
  pname = "dustctl";
  version = "0.2.2";

  src = ../.;

  # `beamPackages` is already scoped to elixir 1.19 (see flake.nix
  # overlay), which dust_cli's mix.exs requires (`elixir ~> 1.19`).
  mixFodDeps = beamPackages.fetchMixDeps {
    pname = "${pname}-mix-deps";
    inherit src version;
    hash = "sha256-lQIVGkiFPZDQxcrbik7y1VoZbabzsjE0ZHQFd4V261Y=";

    env = {
      MIX_ENV = "prod";
    };
  };
in
beamPackages.mixRelease {
  inherit pname version src mixFodDeps;

  releaseType = "release";
  mixEnv = "prod";

  # Keep the auto-generated cookie. dustctl is a short-lived CLI BEAM
  # node, not a clustered service — the cookie is just used to talk to
  # itself, and without it the launcher refuses to start.
  removeCookie = false;

  nativeBuildInputs = [ makeWrapper ];

  patches = [ ./patches/dustctl-no-burrito.patch ];

  # The umbrella's top-level `mix release` builds the daemon release by
  # default; we want the CLI release only.
  mixReleaseName = "dustctl";

  # Build dust_cli from inside its app directory so mix treats it as a
  # standalone project — otherwise `mix release` from the umbrella root
  # tries to compile every umbrella app (dust_api, dust_bridge, ...) and
  # their heavy native deps (cargo, cmake, croaring), none of which the
  # CLI uses.
  configurePhase = ''
    runHook preConfigure
    ln -s "$MIX_DEPS_PATH" ./deps
    cd apps/dust_cli
    mix deps.compile --no-deps-check
    cd "$NIX_BUILD_TOP/$sourceRoot"
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    cd apps/dust_cli
    mix compile --no-deps-check
    cd "$NIX_BUILD_TOP/$sourceRoot"
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cd apps/dust_cli
    mix release dustctl --no-deps-check --path "$out"
    cd "$NIX_BUILD_TOP/$sourceRoot"
    runHook postInstall
  '';

  # Without Burrito, the mix release has no way to receive CLI argv at
  # boot — `bin/dustctl start` just starts the BEAM. The patch under
  # `nix/patches/` rewires `Dust.CLI.Application.start/2` to read argv
  # from the `DUSTCTL_ARGV` env var (newline-separated). Wrap the
  # generated launcher in a small script that packs $@ into that var,
  # then invokes the underlying release in foreground mode.
  postInstall = ''
    mv "$out/bin/dustctl" "$out/bin/.dustctl-release"

    cat > "$out/bin/dustctl" <<'WRAPPER'
    #!/usr/bin/env bash
    set -e
    ARGV=""
    for arg in "$@"; do
      ARGV+="$arg"$'\n'
    done
    export DUSTCTL_ARGV="$ARGV"
    export RELEASE_NAME=dustctl
    exec "$(dirname "$0")/.dustctl-release" start
    WRAPPER

    chmod +x "$out/bin/dustctl"
  '';

  meta = with lib; {
    description = "Command-line client for the Dust daemon";
    homepage = "https://github.com/AndrewBoessen/dust";
    license = licenses.asl20;
    platforms = platforms.unix;
    mainProgram = "dustctl";
  };
}
