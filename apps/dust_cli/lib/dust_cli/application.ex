defmodule Dust.CLI.Application do
  @moduledoc false
  use Application

  def start(_, _) do
    case Burrito.Util.Args.get_bin_path() do
      :not_in_burrito ->
        # Running under mix test or mix run — do not execute the CLI
        Supervisor.start_link([], strategy: :one_for_one)

      _bin_path ->
        args = Burrito.Util.Args.argv()
        exit_code = Dust.CLI.run(args)
        System.halt(exit_code)
    end
  end
end
