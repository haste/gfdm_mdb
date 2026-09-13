defmodule Mix.Tasks.GfdmMdb do
  @moduledoc false

  use Mix.Task
  @shortdoc "Inspect, edit, convert, and verify MDB databases"
  @impl Mix.Task
  @spec run([String.t()]) :: no_return()
  def run(arguments) do
    GfdmMdb.Cli.main(arguments)
  end
end
