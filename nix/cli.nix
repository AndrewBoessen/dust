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
  version = "0.1.2";

  src = ../.;

  mixFodDeps = beamPackages.fetchMixDeps {
    pname = "${pname}-mix-deps";
    inherit src version;
    hash = lib.fakeHash;

    env = {
      MIX_ENV = "prod";
    };
  };
in
beamPackages.mixRelease {
  inherit pname version src mixFodDeps;

  releaseType = "release";
  mixEnv = "prod";

  nativeBuildInputs = [ makeWrapper ];

  patches = [ ./patches/dustctl-no-burrito.patch ];

  # The umbrella's top-level `mix release` builds the daemon release by
  # default; we want the CLI release only.
  mixReleaseName = "dustctl";

  # Wrap the launcher so users invoke it as `dustctl`. The mix release
  # places its launcher at `bin/dustctl` — we just expose it.
  postInstall = ''
    if [ ! -e $out/bin/dustctl ]; then
      ln -s $out/bin/${pname} $out/bin/dustctl || true
    fi
  '';

  meta = with lib; {
    description = "Command-line client for the Dust daemon";
    homepage = "https://github.com/AndrewBoessen/dust";
    license = licenses.asl20;
    platforms = platforms.unix;
    mainProgram = "dustctl";
  };
}
