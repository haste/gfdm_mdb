defmodule GfdmMdb.Cli.RecordPatchTest do
  use ExUnit.Case, async: false

  import GfdmMdb.CliHelpers

  alias GfdmMdb.Fixture

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    input = Path.join(directory, "input.xml")
    database = Fixture.database(203, 6)
    Fixture.write(database, input)

    %{
      input: input,
      output: Path.join(directory, "output.xml"),
      patch: Path.join(directory, "patch.json"),
      song: hd(database.songs),
      course: hd(database.courses)
    }
  end

  test "dotted song and course edits preserve neighboring values", context do
    report =
      json_result(
        ["edit", context.input, "--id", "1120", "--in-place"] ++
          assignments([
            "difficulty.modern.guitar.extreme=750",
            "difficulty.modern.drum.basic=425",
            "difficulty.classic.open.advanced=99",
            "title_name=曲=タイトル"
          ]),
        0
      )

    assert report["valid"]

    assert hd(report["changes"])["fields"]["difficulty.modern.guitar.extreme"] ==
             %{"before" => 0, "after" => 750}

    expected =
      context.song
      |> put_in(["difficulty", "modern", "guitar", "extreme"], 750)
      |> put_in(["difficulty", "modern", "drum", "basic"], 425)
      |> put_in(["difficulty", "classic", "open", "advanced"], 99)
      |> Map.put("title_name", "曲=タイトル")

    assert json_result(["inspect", context.input, "--id", "1120"], 0) == expected

    assert json_result(
             [
               "edit",
               context.input,
               "--kind",
               "courses",
               "--id",
               "-1",
               "--set",
               "difficulty.classic.drum.extreme=95",
               "--in-place"
             ],
             0
           )["valid"]

    expected = put_in(context.course, ["difficulty", "classic", "drum", "extreme"], 95)

    assert json_result(["inspect", context.input, "--kind", "courses", "--id", "-1"], 0) ==
             expected
  end

  test "patch files precede all assignments and repeated assignments apply in order", context do
    modern =
      context.song["difficulty"]["modern"]
      |> put_in(["guitar", "extreme"], 600)
      |> put_in(["bass", "master"], 875)

    File.write!(
      context.patch,
      JSON.encode!(%{"difficulty" => %{"modern" => modern}, "bpm" => 140})
    )

    args =
      ["edit", context.input, "--id", "1120", "--output", context.output] ++
        assignments(["difficulty.modern.guitar.extreme=700", "bpm=150"]) ++
        ["--patch", context.patch] ++
        assignments(["difficulty.modern.guitar.extreme=750"])

    assert assert_preview_matches(args, 0, context.output)["valid"]

    expected =
      context.song
      |> put_in(["difficulty", "modern"], modern)
      |> put_in(["difficulty", "modern", "guitar", "extreme"], 750)
      |> Map.put("bpm", 150)

    assert json_result(["inspect", context.output, "--id", "1120"], 0) == expected
  end

  test "parent object assignments and child assignments honor their order", context do
    guitar = Map.put(context.song["difficulty"]["modern"]["guitar"], "extreme", 700)
    parent = "difficulty.modern.guitar=" <> JSON.encode!(guitar)
    child = "difficulty.modern.guitar.extreme=750"

    for {sets, extreme} <- [{[parent, child], 750}, {[child, parent], 700}] do
      args = ["edit", context.input, "--id", "1120", "--output", context.output, "--force"]
      assert json_result(args ++ assignments(sets), 0)["valid"]
      expected = put_in(context.song, ["difficulty", "modern", "guitar", "extreme"], extreme)
      assert json_result(["inspect", context.output, "--id", "1120"], 0) == expected
    end
  end

  test "invalid paths, objects and values fail before installing output", context do
    File.write!(context.output, "existing output")
    original = File.read!(context.input)

    for {sets, exit} <- [
          {["difficulty.modern.keys.extreme=750"], 2},
          {["contain_stat.0=1"], 2},
          {["difficulty.modern.guitar={}"], 1},
          {["difficulty.modern.guitar.extreme=65536"], 1}
        ] do
      args = ["edit", context.input, "--id", "1120", "--output", context.output, "--force"]
      report = json_result(args ++ assignments(sets), exit)
      refute report["valid"]
      assert File.read!(context.output) == "existing output"
      assert File.read!(context.input) == original
    end
  end

  test "a nested clone edit leaves the original intact and enforces the new ID", context do
    args = [
      "clone",
      context.input,
      "--id",
      "1120",
      "--new-id",
      "2000",
      "--output",
      context.output
    ]

    sets = assignments(["difficulty.modern.guitar.extreme=750"])
    assert json_result(args ++ sets, 0)["valid"]
    assert json_result(["inspect", context.output, "--id", "1120"], 0) == context.song

    expected =
      context.song
      |> Map.put("music_id", 2000)
      |> put_in(["difficulty", "modern", "guitar", "extreme"], 750)

    assert json_result(["inspect", context.output, "--id", "2000"], 0) == expected
    original = File.read!(context.output)

    for id <- [1120, 3000] do
      report = json_result(args ++ sets ++ ["--force", "--set", "music_id=#{id}"], 1)
      refute report["valid"]
      assert File.read!(context.output) == original
    end
  end

  test "dotted edits round trip through binary and reject absent families", context do
    Fixture.write(Fixture.database(), context.input)
    args = ["edit", context.input, "--id", "1120", "--in-place"]
    assert json_result(args ++ ["--set", "difficulty.classic.guitar.extreme=95"], 0)["valid"]
    assert {:ok, database} = Fixture.read(context.input)
    assert hd(database.songs)["difficulty"]["classic"]["guitar"]["extreme"] == 95

    original = File.read!(context.input)
    report = json_result(args ++ ["--set", "difficulty.modern.guitar.extreme=750"], 2)
    assert [%{"code" => "usage"}] = report["errors"]
    assert File.read!(context.input) == original
  end

  defp assignments(values), do: Enum.flat_map(values, &["--set", &1])
end
