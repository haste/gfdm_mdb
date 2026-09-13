defmodule GfdmMdb.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _arguments) do
    arguments =
      if System.get_env("__BURRITO") do
        Enum.map(:init.get_plain_arguments(), &to_string/1)
      else
        System.argv()
      end

    Task.start(GfdmMdb.Cli, :main, [arguments])
  end
end
