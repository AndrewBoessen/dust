defmodule Dust.Api do
  @moduledoc """
  HTTP API layer for the Dust distributed file system daemon.

  Provides a JSON-over-HTTP interface that the CLI and web UI consume to
  interact with all daemon services — file operations, key management,
  cluster administration, configuration, and garbage collection.

  The API server binds to `127.0.0.1:4884` by default (localhost only)
  and authenticates requests using a local bearer token stored at
  `<persist_dir>/api_token`.
  """
end
