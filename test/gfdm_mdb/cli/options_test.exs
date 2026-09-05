defmodule GfdmMdb.Cli.OptionsTest do
  use ExUnit.Case, async: false

  import GfdmMdb.CliHelpers

  alias GfdmMdb.{Database, Fixture}

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    binary = Path.join(directory, "input.bin")
    xml = Path.join(directory, "input.xml")
    json = Path.join(directory, "input.json")
    Fixture.write(Fixture.database(), binary)
    Fixture.write(Fixture.database(203, 6), xml)
    Fixture.write(Fixture.database(203, 6), json, encoding: :json)
    %{binary: binary, xml: xml, json: json, output: Path.join(directory, "output.json")}
  end

  test "input schema hints require XML and failed writes preserve output", context do
    File.write!(context.output, "existing output")

    for input <- [context.binary, context.json] do
      report =
        assert_preview_matches(
          [
            "convert",
            input,
            "--input-schema-version",
            "6",
            "--output",
            context.output,
            "--force"
          ],
          2,
          context.output
        )

      assert [%{"code" => "usage", "message" => message}] = report["errors"]
      assert message =~ "requires an XML input"
      assert File.read!(context.output) == "existing output"
    end

    report = json_result(["inspect", context.xml, "--input-schema-version", "5"], 1)
    refute report["valid"]
  end

  test "empty XML uses the input hint while target selects the output schema", context do
    Fixture.write(Database.new(203, 4), context.xml)
    report = json_result(["inspect", context.xml, "--input-schema-version", "4"], 0)
    assert report["counts"] == %{"songs" => 0, "courses" => 0}

    assert json_result(
             [
               "convert",
               context.xml,
               "--input-schema-version",
               "4",
               "--target",
               "203:6",
               "--output",
               context.output
             ],
             0
           )["valid"]

    assert {:ok, %{format: 203, schema_version: 6}} = Fixture.read(context.output)
  end

  test "explicit identity requires the resolved output format to be JSON", context do
    File.write!(context.output, "existing output")

    for {input, format} <- [{context.binary, "binary"}, {context.xml, "xml"}] do
      report =
        assert_preview_matches(
          [
            "convert",
            input,
            "--identity",
            "mt",
            "--output-format",
            format,
            "--output",
            context.output,
            "--force"
          ],
          2,
          context.output
        )

      assert [%{"code" => "usage", "message" => message}] = report["errors"]
      assert message =~ "--identity requires JSON output"
      assert File.read!(context.output) == "existing output"
    end

    report = json_result(["convert", context.json, "--identity", "mt", "--dry-run"], 2)
    assert [%{"code" => "usage"}] = report["errors"]
  end

  test "explicit JSON output, inferred output and in-place edits preserve identity", context do
    args = [
      "convert",
      context.xml,
      "--output-format",
      "json",
      "--identity",
      "mt",
      "--output",
      context.binary,
      "--force"
    ]

    assert assert_preview_matches(args, 0, context.binary)["valid"]
    assert {:ok, %{identity: "mt"}} = Fixture.read(context.binary)

    args = ["edit", context.binary, "--id", "1120", "--set", "bpm=150", "--in-place"]
    assert json_result(args ++ ["--identity", "overridden"], 0)["valid"]
    assert {:ok, %{identity: "overridden"}} = Fixture.read(context.binary)

    assert json_result(
             ["convert", context.xml, "--identity", "mt", "--output", context.output],
             0
           )["valid"]

    assert {:ok, %{identity: "mt"}} = Fixture.read(context.output)

    # Native output may omit stored identity when no identity option was supplied.
    assert json_result(["convert", context.output, "--output", context.xml, "--force"], 0)[
             "valid"
           ]

    assert {:ok, %{identity: nil}} = Fixture.read(context.xml)
  end

  test "reindex reads key files and requires an explicit flag to clear stored kana ranks",
       context do
    database = Fixture.database(203, 6)

    song =
      Map.merge(hd(database.songs), %{
        "order_kana" => 7,
        "category_kana" => 65,
        "artist_order_kana" => 8
      })

    Fixture.write(%{database | songs: [song]}, context.xml)
    keys = Path.join(context.tmp_dir, "keys.json")
    File.write!(keys, JSON.encode!(%{"1120" => %{"title" => %{"ascii" => "A"}}}))
    args = ["reindex", context.xml, "--keys", keys, "--output", context.output]

    report = json_result(args, 1)
    assert [%{"code" => "sort_keys", "path" => "title.kana"}] = report["errors"]
    refute File.exists?(context.output)

    assert json_result(List.insert_at(args, 1, "--clear-missing-kana"), 0)["valid"]
    assert {:ok, cleared} = Fixture.read(context.output)

    assert hd(cleared.songs) ==
             Map.merge(song, %{"order_ascii" => 1, "order_kana" => 0, "category_kana" => 0})

    File.write!(
      keys,
      JSON.encode!(%{
        "1120" => %{"title" => %{"ascii" => "A", "kana" => "ア", "category" => "A"}}
      })
    )

    assert json_result(List.insert_at(args, 1, "--force"), 0)["valid"]
    assert {:ok, supplied} = Fixture.read(context.output)
    assert hd(supplied.songs) == Map.merge(song, %{"order_ascii" => 1, "order_kana" => 1})
  end
end
