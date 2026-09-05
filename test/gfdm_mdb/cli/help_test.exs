defmodule GfdmMdb.Cli.HelpTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias GfdmMdb.Cli
  alias GfdmMdb.Cli.Arguments

  test "overview and command help work without input files" do
    commands = ~w(inspect verify convert add clone edit remove reindex)
    overview = capture_io(fn -> assert Cli.run(["--help"]) == 0 end)

    for command <- commands do
      assert overview =~ command
      text = capture_io(fn -> assert Cli.run([command, "--help"]) == 0 end)
      assert text =~ "gfdm_mdb #{command}"
    end
  end

  test "arguments preserve paths and negative IDs and apply repeated options in order" do
    assert {:ok, %{input: "曲.bin", options: opts}} =
             Arguments.parse([
               "edit",
               "曲.bin",
               "--id",
               "999",
               "--id",
               "-1",
               "-oout.json",
               "--set",
               "bpm=150",
               "--set",
               "bpm=160",
               "--encrypted",
               "--no-encrypted"
             ])

    assert opts.id == -1
    assert opts.output == "out.json"
    assert opts.encrypted == false
    assert opts.set == ["bpm=150", "bpm=160"]

    assert {:ok, %{input: "--help"}} = Arguments.parse(["inspect", "--", "--help"])
  end
end
