{ lib
, stdenv
, beamPackages
, fetchFromGitHub
, rustPlatform
, cmake
, gnumake
, pkg-config
, gcc
, git
, rustc
, cargo
, go
, snappy
, openssl
, zlib
, zstd
, lz4
, bzip2
, ncurses
, tsnetSidecar
}:

# Builds the top-level Dust release (`mix release dust`) for NixOS.
#
# Native dependency notes
# ────────────────────────
# * Rust NIFs (`rs_simd`, `disk_space`) use plain Rustler — compiled from
#   source. We vendor their Cargo deps via `importCargoLock`.
# * The hex `rocksdb` package vendors the upstream rocksdb sources but its
#   rebar.config has a `git submodule update --init --recursive` pre_hook
#   that fails in the Nix sandbox (no `.git` dir in a fetched dep). We
#   strip that line.
# * `argon2_elixir` is a `:make` C build — needs gcc + gnumake.
# * The Go tsnet sidecar is built separately in `nix/tsnet-sidecar.nix`
#   and overlaid into `dust_bridge`'s priv dir in `postInstall`.
let
  pname = "dust";
  version = "0.2.1";

  src = ../.;

  # Fixed-output derivation containing the BEAM-fetched hex deps. Patched
  # post-fetch so the rocksdb dep no longer tries to run `git submodule`,
  # and so `disk_space` (whose hex tarball omits Cargo.lock) has one
  # generated for `importCargoLock` below.
  #
  # `cargo` is added via overrideAttrs so we don't drop fetchMixDeps's
  # default buildInputs (elixir/hex/rebar3/rebar).
  mixFodDeps = (beamPackages.fetchMixDeps {
    pname = "${pname}-mix-deps";
    inherit src version;
    hash = "sha256-YIoG5K9+gxVFkpUn1UgrNM87npGYJYuMAcE/s72y4kg=";

    # Make `mix deps.get` work in the sandbox.
    env = {
      HEX_OFFLINE = "0";
      MIX_ENV = "prod";
    };

    # `fetchMixDeps` sets `dontBuild = true` and copies $TEMPDIR/deps to
    # $out inside its installPhase, so patches must run in postInstall
    # against $out/<dep>/... — postBuild is never invoked.
    postInstall = ''
      if [ -f $out/rocksdb/rebar.config ]; then
        chmod -R u+w $out/rocksdb
        substituteInPlace $out/rocksdb/rebar.config \
          --replace-quiet \
            '{compile, "git submodule update --init --recursive"},' \
            ""
      fi

      # `disk_space` is a Cargo workspace whose hex package omits
      # Cargo.lock. Generate one here so `importCargoLock` can read it.
      if [ -f $out/disk_space/Cargo.toml ] && [ ! -f $out/disk_space/Cargo.lock ]; then
        chmod -R u+w $out/disk_space
        export HOME=$TMPDIR
        export CARGO_HOME=$TMPDIR/cargo
        mkdir -p "$CARGO_HOME"
        (cd $out/disk_space && cargo generate-lockfile)
      fi
    '';
  }).overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ cargo ];
  });

  # Vendor the Cargo deps for the two Rust NIFs. Both lockfiles live
  # under deps/ inside `mixFodDeps`. Reading them through the FOD output
  # is IFD, but it means we don't need to commit copies of the lockfiles
  # into the repo — the hex-fetched sources are the source of truth.
  rsSimdCargoVendor = rustPlatform.importCargoLock {
    lockFile = "${mixFodDeps}/rs_simd/native/rs_simd_nif/Cargo.lock";
  };

  diskSpaceCargoVendor = rustPlatform.importCargoLock {
    lockFile = "${mixFodDeps}/disk_space/Cargo.lock";
  };
in
beamPackages.mixRelease {
  inherit pname version src mixFodDeps;

  releaseType = "release";
  mixEnv = "prod";

  nativeBuildInputs = [
    cmake
    gnumake
    pkg-config
    gcc
    git
    rustc
    cargo
    go
  ];

  buildInputs = [
    snappy
    openssl
    zlib
    zstd
    lz4
    bzip2
    ncurses
  ];

  # The hex rocksdb's CMakeLists turns CRoaring on by default. CRoaring's
  # FindLTO.cmake isn't shipped in the hex tarball (it's a git submodule
  # we don't pull), and dust doesn't use posting-list bitmap operations,
  # so disable it via the env var that the rocksdb rebar pre_hook passes
  # to `./do_cmake.sh`.
  ERLANG_ROCKSDB_OPTS = "-DWITH_CROARING=OFF";

  # Wire vendored cargo deps into each NIF's source tree before mix
  # invokes rustler. This MUST happen in preConfigure — mixRelease's
  # configurePhase runs `mix deps.compile --skip-umbrella-children`,
  # which is when rs_simd's rustler shells out to cargo. preBuild runs
  # AFTER that, so it's too late.
  #
  # `importCargoLock` ships its own .cargo/config.toml with a relative
  # `directory = "cargo-vendor-dir"`, which doesn't resolve in our
  # layout — we write fresh configs pointing at the absolute store
  # paths instead.
  preConfigure = ''
    export HOME=$TMPDIR
    export CARGO_HOME=$TMPDIR/cargo
    mkdir -p $CARGO_HOME

    # mixRelease's postUnpack uses `cp --no-preserve=mode`, which strips
    # the +x bit off shell scripts in the dep tree. Restore it for
    # anything rocksdb's rebar pre_hooks shells out to.
    if [ -d $MIX_DEPS_PATH/rocksdb ]; then
      chmod +x $MIX_DEPS_PATH/rocksdb/do_cmake.sh 2>/dev/null || true
      find $MIX_DEPS_PATH/rocksdb -maxdepth 2 -name '*.sh' -exec chmod +x {} +
    fi

    mkdir -p $MIX_DEPS_PATH/rs_simd/native/rs_simd_nif/.cargo
    cat > $MIX_DEPS_PATH/rs_simd/native/rs_simd_nif/.cargo/config.toml <<EOF
    [source.crates-io]
    replace-with = "vendored-sources"

    [source.vendored-sources]
    directory = "${rsSimdCargoVendor}"
    EOF

    mkdir -p $MIX_DEPS_PATH/disk_space/.cargo
    cat > $MIX_DEPS_PATH/disk_space/.cargo/config.toml <<EOF
    [source.crates-io]
    replace-with = "vendored-sources"

    [source.vendored-sources]
    directory = "${diskSpaceCargoVendor}"
    EOF

    # rocksdb cmake build picks these up via find_package / pkg-config.
    export PKG_CONFIG_PATH="${snappy.dev}/lib/pkgconfig:${openssl.dev}/lib/pkgconfig:$PKG_CONFIG_PATH"
  '';

  # Drop the Go sidecar into the priv dir of the dust_bridge app inside
  # the assembled release so the daemon can find it at runtime.
  postInstall = ''
    bridgePriv=$(find $out/lib -maxdepth 2 -type d -name 'dust_bridge-*' -print -quit)/priv
    mkdir -p "$bridgePriv"
    # buildGoModule names the binary after the Go module (`dust_sidecar`),
    # but Dust.Bridge launches it as `tsnet_sidecar`. Copy with the
    # expected name.
    cp ${tsnetSidecar}/bin/dust_sidecar "$bridgePriv/tsnet_sidecar"
    chmod +x "$bridgePriv/tsnet_sidecar"
  '';

  meta = with lib; {
    description = "Dust distributed file system daemon";
    homepage = "https://github.com/AndrewBoessen/dust";
    license = licenses.asl20;
    platforms = platforms.unix;
    mainProgram = "dust";
  };
}
