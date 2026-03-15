defmodule Core do
  @moduledoc """
  Core cryptographic primitives and file-handling logic for the Dust network.

  Submodules:

    * `Dust.Core.Crypto`   — AES-256-GCM encryption/decryption, key types, and `FileMeta`/`ChunkMeta` structs
    * `Dust.Core.KeyStore`  — master-key lifecycle (generation, persistence, peer sync)
    * `Dust.Core.Packer`    — split and encrypt files into network-ready chunks
    * `Dust.Core.Unpacker`  — decrypt chunks back into plaintext
  """
end
