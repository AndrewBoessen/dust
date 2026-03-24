defmodule Dust.Core do
  @moduledoc """
  Core cryptographic primitives and file-handling logic for the Dust network.

  Submodules:

    * `Dust.Core.Crypto`        — AES-256-GCM encryption/decryption, key types, and `FileMeta`/`ChunkMeta` structs
    * `Dust.Core.ErasureCoding` — Reed-Solomon erasure coding for data redundancy
    * `Dust.Core.KeyStore`      — master-key lifecycle (generation, persistence, peer sync)
    * `Dust.Core.Packer`        — split and encrypt files into network-ready chunks
    * `Dust.Core.Unpacker`      — decrypt chunks back into plaintext
    * `Dust.Core.Fitness`       — score node fitness based on network stats
  """
end
