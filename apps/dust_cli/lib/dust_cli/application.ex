defmodule Dust.CLI.Application do
  @moduledoc false
  use Application

  def start(_, _) do
    args = Burrito.Util.Args.argv()
    exit_code = Dust.CLI.run(args)
    System.halt(exit_code)
  end
end
