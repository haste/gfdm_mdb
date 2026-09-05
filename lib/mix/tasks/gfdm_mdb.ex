defmodule Mix.Tasks.GfdmMdb do
  @moduledoc false

  use Mix.Task
  @shortdoc "Inspect, edit, convert, and verify MDB databases"
  @impl Mix.Task
  def run(arguments) do
    GfdmMdb.Cli.main(arguments)
  end
end
