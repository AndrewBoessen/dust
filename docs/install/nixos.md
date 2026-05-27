# NixOS Install

Dust ships a Nix flake. The release tarballs **do not work** on NixOS
(dynamic linker paths and system libraries are managed by Nix), so use
the flake's NixOS module instead.

## Daemon

Add to your system flake:

```nix
{
  inputs.dust.url = "github:AndrewBoessen/dust";

  outputs = { self, nixpkgs, dust, ... }: {
    nixosConfigurations.example = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        dust.nixosModules.default
        ({ ... }: {
          nixpkgs.overlays = [ dust.overlays.default ];

          services.dust.enable = true;
        })
      ];
    };
  };
}
```

Then `sudo nixos-rebuild switch`, and log out and back in so your shell
picks up the new group membership. The module creates a `dust` user,
provisions `/var/lib/dust` and `/var/log/dust`, and registers a systemd
unit that starts on boot. See
[Configuration → NixOS](../configuration.md#nixos) for the full list of
`services.dust.*` options.

`dustctl daemon install` / `uninstall` are inert on NixOS — they exit
non-zero with a pointer back to this section, because service config is
managed declaratively here, not by writing to `/etc/systemd/system/`.

## CLI (`dustctl`)

The CLI is also exposed by the flake:

```bash
# Run without installing
nix run github:AndrewBoessen/dust#dustctl -- status

# Or install system-wide through the overlay
nixpkgs.overlays = [ inputs.dust.overlays.default ];
environment.systemPackages = [ pkgs.dustctl ];
```

The Nix package builds a plain mix release (no burrito), so the
executable lives at `${pkgs.dustctl}/bin/dustctl`.

If you're talking to a daemon managed by `services.dust`, add your
account to the `dust` group so the CLI can read the API token:

```nix
users.users.alice.extraGroups = [ "dust" ];
```

Without this, `dustctl` will report a permission error on
`/var/lib/dust/api_token`. See
[Configuration → NixOS](../configuration.md#nixos) for the full setup.

---

**Next:** [Getting Started](../getting-started.md) — first-node setup
walkthrough.
