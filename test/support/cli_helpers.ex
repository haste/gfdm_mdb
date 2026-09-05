defmodule GfdmMdb.CliHelpers do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.CaptureIO

  alias GfdmMdb.Cli

  def json_result(args, exit) do
    args = if "--json" in args, do: args, else: List.insert_at(args, 1, "--json")

    capture_io(fn ->
      assert capture_io(:stderr, fn -> assert Cli.run(args) == exit end) == ""
    end)
    |> JSON.decode!()
  end

  def assert_preview_matches(args, exit, output) do
    original = File.read(output)
    preview = json_result(List.insert_at(args, 1, "--dry-run"), exit)
    assert File.read(output) == original
    actual = json_result(args, exit)

    if exit == 0 do
      assert preview["dry_run"]
      assert actual == preview |> Map.delete("dry_run") |> Map.put("output", output)
    else
      assert actual == preview
    end

    actual
  end
end
