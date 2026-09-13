defmodule GfdmMdb.CliTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  import GfdmMdb.CliHelpers
  alias GfdmMdb.{Cli, Database, Fixture, Schema}
  alias GfdmMdb.Codec.Json

  @moduletag :tmp_dir
  setup %{tmp_dir: directory} do
    input = Path.join(directory, "input.bin")
    :ok = Fixture.write(Fixture.database(), input)
    %{input: input}
  end

  test "verification reports malformed files and makes warnings fatal only with strict", %{
    input: input
  } do
    assert json_result(["verify", input], 0)["valid"]
    database = %{Fixture.database() | songs: []}
    Fixture.write(database, input)
    assert [%{"code" => "reference"}] = json_result(["verify", input], 0)["warnings"]
    refute json_result(["verify", input, "--strict"], 1)["valid"]

    File.write!(input, "broken")
    assert [%{"code" => "magic"}] = json_result(["verify", input], 1)["errors"]
  end

  test "failed writes preserve files and force permits a valid replacement", %{
    input: input,
    tmp_dir: directory
  } do
    original = File.read!(input)
    output = Path.join(directory, "edited.bin")
    args = ["edit", input, "--id", "1120", "--set", "bpm=150", "--output", output]

    File.write!(output, "existing output")
    assert [%{"code" => "file"}] = json_result(args, 1)["errors"]
    assert File.read!(output) == "existing output"

    invalid = [
      "edit",
      input,
      "--id",
      "1120",
      "--set",
      "bpm=999999",
      "--output",
      output,
      "--force"
    ]

    assert [%{"code" => "invalid_value"}] = json_result(invalid, 1)["errors"]
    assert File.read!(output) == "existing output"
    assert json_result(List.insert_at(args, 1, "--force"), 0)["valid"]
    assert {:ok, updated} = Fixture.read(output)
    assert hd(updated.songs)["bpm"] == 150
    assert File.read!(input) == original
    assert Path.wildcard(Path.join(directory, "*.tmp")) == []
  end

  test "invalid database and patch files fail without replacing the destination", %{
    input: input,
    tmp_dir: directory
  } do
    output = Path.join(directory, "output.bin")
    patch = Path.join(directory, "patch.json")
    original = File.read!(input)
    File.write!(output, "existing output")

    for {bytes, code, exit} <- [{"{", "json", 1}, {"[]", "usage", 2}] do
      File.write!(patch, bytes)
      args = ["edit", input, "--id", "1120", "--patch", patch, "--output", output, "--force"]
      assert [%{"code" => ^code}] = json_result(args, exit)["errors"]
      assert File.read!(output) == "existing output"
    end

    invalid = Json.envelope(Fixture.database()) |> Map.put("songs", [nil])
    File.write!(patch, JSON.encode!(invalid))

    args = ["edit", patch, "--id", "1120", "--set", "bpm=150", "--output", output, "--force"]
    assert [%{"code" => "record"}] = json_result(args, 1)["errors"]

    assert File.read!(output) == "existing output"
    assert File.read!(input) == original
  end

  test "in-place edits preserve storage regardless of the filename", %{tmp_dir: directory} do
    for {format, version, encoding, encrypted, name} <- [
          {102, nil, :binary, false, "plain.xml"},
          {102, nil, :binary, true, "encrypted.json"},
          {102, nil, :json, true, "extensionless"},
          {203, 4, :xml, false, "xml.bin"}
        ] do
      input = Path.join(directory, name)

      assert :ok =
               Fixture.write(Fixture.database(format, version), input,
                 encoding: encoding,
                 encrypted: encrypted
               )

      assert capture_io(fn ->
               assert Cli.run(["edit", input, "--in-place", "--id", "1120", "--set", "bpm=150"]) ==
                        0
             end) =~ "Wrote"

      assert GfdmMdb.detect_encoding(File.read!(input)) == encoding
      assert {:ok, updated} = Fixture.read(input)
      assert hd(updated.songs)["bpm"] == 150
      assert updated.encrypted == encrypted
    end

    assert Path.wildcard(Path.join(directory, "*.tmp")) == []
  end

  test "in-place dry runs, invalid edits and conflicting options preserve input", %{input: input} do
    original = File.read!(input)
    args = ["edit", input, "--in-place", "--id", "1120"]

    assert capture_io(fn -> assert Cli.run(args ++ ["--set", "bpm=150", "--dry-run"]) == 0 end) =~
             "Dry run:"

    assert File.read!(input) == original

    assert capture_io(:stderr, fn -> assert Cli.run(args ++ ["--set", "bpm=999999"]) == 1 end) =~
             "invalid_value"

    assert File.read!(input) == original

    assert capture_io(:stderr, fn ->
             assert Cli.run(args ++ ["--set", "bpm=150", "--output", input]) == 2
           end) =~ "Choose --in-place or --output"

    assert File.read!(input) == original
  end

  test "in-place conversion accepts explicit encoding and encryption changes", %{input: input} do
    assert capture_io(fn ->
             assert Cli.run(["convert", input, "--in-place", "--encrypted"]) == 0
           end) =~ "Wrote"

    assert {:ok, encrypted} = Fixture.read(input)
    assert encrypted.encrypted

    assert capture_io(fn ->
             assert Cli.run(["convert", input, "--in-place", "--output-format", "json"]) == 0
           end) =~ "Wrote"

    assert GfdmMdb.detect_encoding(File.read!(input)) == :json

    assert capture_io(fn ->
             assert Cli.run(["convert", input, "--in-place", "--target", "101"]) == 0
           end) =~ "Wrote"

    assert GfdmMdb.detect_encoding(File.read!(input)) == :json
    assert {:ok, converted} = Fixture.read(input)
    assert converted.format == 101
    assert converted.encrypted
  end

  test "in-place native conversion follows the target format", %{input: input} do
    assert :ok = Fixture.write(GfdmMdb.Database.new(102), input)

    assert capture_io(fn ->
             assert Cli.run(["convert", input, "--in-place", "--target", "203:4"]) == 0
           end) =~ "Wrote"

    assert GfdmMdb.detect_encoding(File.read!(input)) == :xml

    assert capture_io(fn ->
             assert Cli.run([
                      "convert",
                      input,
                      "--in-place",
                      "--input-schema-version",
                      "4",
                      "--target",
                      "102"
                    ]) == 0
           end) =~ "Wrote"

    assert {:ok, database} = Fixture.read(input)
    assert database.format == 102
    assert database.songs == []
  end

  test "JSON conversion and rebuild preserve encryption and explicit format overrides the extension",
       %{
         tmp_dir: directory,
         input: input
       } do
    json = Path.join(directory, "database.json")
    binary = Path.join(directory, "database.xml")
    Fixture.write(Fixture.database(), input, encrypted: true)
    original = File.read!(input)
    assert json_result(["convert", input, "--output", json], 0)["valid"]
    assert JSON.decode!(File.read!(json))["native"]["encrypted"]

    assert json_result(
             ["convert", json, "--output", binary, "--output-format", "binary"],
             0
           )["valid"]

    assert File.read!(binary) == original
    assert {:ok, database} = Fixture.read(binary)
    assert database.encrypted
  end

  test "text warnings use stderr and JSON reports use only stdout", %{input: input} do
    args = ["remove", input, "--id", "1120", "--dry-run"]

    output =
      capture_io(fn ->
        warnings = capture_io(:stderr, fn -> assert Cli.run(args) == 0 end)
        assert warnings =~ "Song 1120 is absent"
      end)

    assert output =~ "Dry run: valid output,"
    assert [%{"code" => "reference"}] = json_result(args, 0)["warnings"]
  end

  test "record listings and details are readable unless JSON is requested", %{input: input} do
    listing = capture_io(fn -> assert Cli.run(["inspect", input, "--records"]) == 0 end)
    assert listing =~ "WHITE ｔORNADO"

    details = capture_io(fn -> assert Cli.run(["inspect", input, "--id", "1120"]) == 0 end)
    assert details =~ "music_id: 1120"
    assert details =~ "guitar_offset: -128"
    assert details =~ "difficulty.classic.guitar.basic: 0"

    json = capture_io(fn -> assert Cli.run(["inspect", input, "--id", "1120", "--json"]) == 0 end)
    assert JSON.decode!(json)["music_id"] == 1120

    assert capture_io(:stderr, fn -> assert Cli.run(["inspect", input, "--id", "999"]) == 1 end) =~
             "not_found:"

    assert capture_io(:stderr, fn ->
             assert Cli.run(["inspect", input, "--records", "--id", "1120"]) == 2
           end) =~ "Choose --records or --id"
  end

  test "inspected records can be added and patched with named difficulties", %{
    tmp_dir: directory
  } do
    input = Path.join(directory, "modern.xml")
    record_path = Path.join(directory, "song.json")
    output = Path.join(directory, "edited.json")
    patch_path = Path.join(directory, "patch.json")
    Fixture.write(Fixture.database(203, 6), input)

    original = json_result(["inspect", input, "--id", "1120"], 0)

    song =
      original
      |> Map.put("music_id", 2000)
      |> put_in(["difficulty", "modern", "drum", "basic"], 425)

    File.write!(record_path, Json.pretty(song))
    assert json_result(["add", input, "--record", record_path, "--output", output], 0)["valid"]

    record = json_result(["inspect", output, "--id", "2000"], 0)
    assert record == song
    assert {:ok, database} = Fixture.read(output)
    assert Database.header(database)["record_count"] == 2

    modern =
      put_in(song, ["difficulty", "modern", "guitar", "extreme"], 875)["difficulty"]["modern"]

    File.write!(
      patch_path,
      Json.pretty(%{"difficulty" => %{"modern" => modern}, "guitar_offset" => -5})
    )

    assert json_result(["edit", output, "--id", "2000", "--patch", patch_path, "--in-place"], 0)[
             "valid"
           ]

    record = json_result(["inspect", output, "--id", "2000"], 0)
    assert record["difficulty"]["modern"]["guitar"]["extreme"] == 875
    assert record["difficulty"]["modern"]["drum"]["basic"] == 425
    assert record["difficulty"]["classic"] == song["difficulty"]["classic"]
    assert record["guitar_offset"] == -5

    assert json_result(
             ["edit", output, "--id", "2000", "--set", "modern_seq_flag=3", "--in-place"],
             0
           )["valid"]

    assert json_result(["inspect", output, "--id", "2000"], 0)["modern_seq_flag"] == 3
  end

  test "conversion defaults and overrides use the same JSON field names", %{
    input: input,
    tmp_dir: directory
  } do
    defaults_path = Path.join(directory, "defaults.json")
    overrides_path = Path.join(directory, "overrides.json")
    output = Path.join(directory, "modern.bin")
    target = Schema.song_fields(202) |> Schema.template()

    defaults =
      target
      |> Map.take(
        ~w(first_modern_ver modern_seq_flag modern_secret modern_b_session modern_active_effect_type modern_movie_disp_type modern_movie_disp_id)
      )
      |> Map.put("difficulty", target["difficulty"])
      |> Map.put("bpm", 1)
      |> put_in(["difficulty", "classic", "guitar", "basic"], 99)
      |> put_in(["difficulty", "modern", "guitar", "extreme"], 750)

    File.write!(defaults_path, Json.pretty(defaults))

    File.write!(
      overrides_path,
      Json.pretty(%{"1120" => %{"first_modern_ver" => [3, 4], "modern_movie_disp_id" => 5}})
    )

    assert json_result(
             [
               "convert",
               input,
               "--target",
               "202",
               "--defaults",
               defaults_path,
               "--overrides",
               overrides_path,
               "--allow-loss",
               "--output",
               output
             ],
             0
           )["valid"]

    assert {:ok, database} = Fixture.read(output)
    assert hd(database.songs)["first_modern_ver"] == [3, 4]
    assert hd(database.songs)["modern_movie_disp_id"] == 5
    assert hd(database.songs)["bpm"] == 120
    assert hd(database.songs)["difficulty"]["modern"]["guitar"]["extreme"] == 750

    assert hd(database.songs)["difficulty"]["classic"] ==
             hd(Fixture.database().songs)["difficulty"]["classic"]
  end

  test "JSON staging edits fields from newer schemas and retains null placeholders", %{
    input: input,
    tmp_dir: directory
  } do
    json = Path.join(directory, "intermediate.json")
    xml = Path.join(directory, "new.xml")
    patch = Path.join(directory, "new-fields.json")
    Fixture.write(Fixture.database(203, 3), input)
    assert json_result(["convert", input, "--output", json], 0)["valid"]

    assert json_result(
             [
               "edit",
               json,
               "--id",
               "1120",
               "--set",
               "data_ver=119",
               "--set",
               "artist_title_ascii=An artist",
               "--in-place"
             ],
             0
           )["valid"]

    assert json_result(["verify", json], 0)["valid"]
    staged = JSON.decode!(File.read!(json))

    assert [%{"data_ver" => 119, "artist_title_ascii" => "An artist", "seq_id" => nil}] =
             staged["songs"]

    File.write!(
      patch,
      Json.pretty(%{
        "artist_order_ascii" => 0,
        "artist_order_kana" => 0,
        "artist_category_kana" => 0
      })
    )

    assert json_result(["edit", json, "--id", "1120", "--patch", patch, "--in-place"], 0)["valid"]

    assert json_result(["convert", json, "--target", "203:6", "--output", xml], 0)["valid"]
    assert {:ok, target} = Fixture.read(xml)
    assert hd(target.songs)["data_ver"] == 119
    assert hd(target.songs)["seq_id"] == 1120
    assert hd(target.songs)["artist_title_ascii"] == "An artist"
  end

  test "conversion previews and writes reject the same unencodable output", %{
    input: input,
    tmp_dir: directory
  } do
    xml = Path.join(directory, "input.xml")
    overrides = Path.join(directory, "overrides.json")
    :ok = Fixture.write(Fixture.database(203, 4), xml)
    File.write!(overrides, JSON.encode!(%{"1120" => %{"title_name" => "x\0y"}}))
    output = Path.join(directory, "output.xml")

    for {source, options, code} <- [
          {input, ["--target", "101"], "schema"},
          {xml, ["--target", "203:4", "--encrypted"], "metadata"},
          {xml, ["--target", "203:4", "--overrides", overrides], "xml_character"}
        ] do
      args = ["convert", source, "--output", output, "--json"] ++ options
      actual = assert_preview_matches(args, 1, output)
      assert hd(actual["errors"])["code"] == code

      refute File.exists?(output)
    end

    assert {:ok, database} = Fixture.read(input)
    assert database == Fixture.database()
  end

  test "conversion reports retain loss details in previews, writes and failures", %{
    input: input,
    tmp_dir: directory
  } do
    output = Path.join(directory, "converted.bin")
    args = ["convert", input, "--target", "100", "--output", output, "--json"]
    failure = assert_preview_matches(args, 1, output)
    refute failure["valid"]
    removed = ~w(songs.genre songs.is_remaster songs.music_type songs.origin)
    assert Enum.sort(Enum.map(failure["conversion"]["issues"], & &1["path"])) == removed
    refute File.exists?(output)

    text =
      capture_io(:stderr, fn ->
        assert Cli.run(List.delete(args, "--json")) == 1
      end)

    assert text =~ "Removing source fields requires --allow-loss"
    assert text =~ "removed: songs.genre [ID 1120]"

    args = List.insert_at(args, 1, "--allow-loss")
    actual = assert_preview_matches(args, 0, output)
    assert actual["valid"]
    assert Enum.sort(Enum.map(actual["conversion"]["issues"], & &1["path"])) == removed
    assert {:ok, database} = Fixture.read(output)
    assert database.format == 100
  end

  test "usage errors exit with 2 and operation errors exit with 1 in text and JSON", %{
    input: input,
    tmp_dir: directory
  } do
    missing = Path.join(directory, "missing")

    for {args, exit, code} <- [
          {["unknown"], 2, "usage"},
          {["inspect"], 2, "usage"},
          {["inspect", input, input], 2, "usage"},
          {["inspect", input, "--unknown"], 2, "usage"},
          {["clone", input, "--id", "1120", "--new-id", "invalid", "--dry-run"], 2, "usage"},
          {["clone", input, "--id", "1120", "--dry-run"], 2, "usage"},
          {["inspect", missing], 1, "file"},
          {["edit", input, "--id", "999", "--set", "bpm=150", "--dry-run"], 1, "not_found"},
          {["edit", input, "--id", "1120", "--set", "bpm", "--dry-run"], 2, "usage"},
          {["edit", input, "--id", "1120", "--set", "bpm=invalid", "--dry-run"], 1, "json"},
          {["edit", input, "--id", "1120", "--set", "bpm=999999", "--dry-run"], 1,
           "invalid_value"},
          {["convert", input, "--output", input], 1, "file"}
        ] do
      report = json_result(List.insert_at(args, 1, "--json"), exit)
      assert report["valid"] == false
      assert hd(report["errors"])["code"] == code

      assert capture_io(:stderr, fn ->
               assert capture_io(fn -> assert Cli.run(args) == exit end) == ""
             end) =~ "#{code}:"
    end
  end

  test "record mutations share preview and write behavior", %{input: input, tmp_dir: directory} do
    original = File.read!(input)
    record = Path.join(directory, "record.json")
    song = Fixture.database().songs |> hd() |> Map.put("music_id", 2)
    File.write!(record, JSON.encode!(song))

    for {command, options, ids} <- [
          {"add", ["--record", record], [2, 1120]},
          {"clone", ["--id", "1120", "--new-id", "2"], [2, 1120]},
          {"edit", ["--id", "1120", "--set", "bpm=151", "--set", "title_ascii=Changed"], [1120]},
          {"remove", ["--id", "1120"], []},
          {"reindex", ["--use-stored-keys"], [1120]}
        ] do
      output = Path.join(directory, command <> ".json")
      args = [command, input, "--output", output, "--json"] ++ options
      actual = assert_preview_matches(args, 0, output)
      assert File.read!(input) == original
      assert {:ok, database} = Fixture.read(output)
      assert Enum.map(database.songs, & &1["music_id"]) == ids
      assert Database.header(database)["record_count"] == length(ids)

      case command do
        "edit" ->
          assert hd(database.songs)["bpm"] == 151
          assert hd(database.songs)["title_ascii"] == "Changed"

          assert actual["changes"] == [
                   %{
                     "kind" => "songs",
                     "record_id" => 1120,
                     "action" => "updated",
                     "fields" => %{
                       "bpm" => %{"before" => 120, "after" => 151},
                       "title_ascii" => %{"before" => "WHITE ｔORNADO", "after" => "Changed"}
                     }
                   }
                 ]

        "reindex" ->
          assert hd(database.songs)["order_ascii"] == 1
          assert actual["reindex"]["select"] == "title"
          assert hd(actual["changes"])["fields"]["order_ascii"] == %{"before" => 0, "after" => 1}

        "remove" ->
          assert actual["warnings"] != []

          assert actual["changes"] == [
                   %{"kind" => "songs", "record_id" => 1120, "action" => "removed"}
                 ]

        _command ->
          assert database.courses == Fixture.database().courses
      end
    end
  end

  @tag skip: match?({:win32, _}, :os.type())
  test "replacement preserves existing Unix permissions", %{input: input} do
    File.chmod!(input, 0o640)
    args = ["edit", input, "--id", "1120", "--set", "bpm=151", "--in-place"]
    assert json_result(args, 0)["valid"]
    assert Bitwise.band(File.stat!(input).mode, 0o777) == 0o640
  end

  test "inspection distinguishes JSON input and filters record collections", %{
    input: input,
    tmp_dir: directory
  } do
    json = Path.join(directory, "database.bin")
    :ok = Fixture.write(Fixture.database(), json, encoding: :json, encrypted: true)
    text = capture_io(fn -> assert Cli.run(["inspect", json]) == 0 end)
    assert text =~ "Input encoding: JSON"
    assert text =~ "Native storage: MDBE (encrypted binary)"
    assert json_result(["inspect", json, "--json"], 0)["input_encoding"] == "json"

    for kind <- ["songs", "courses"] do
      args = ["inspect", input, "--records", "--kind", kind]
      report = json_result(List.insert_at(args, 1, "--json"), 0)
      assert Map.has_key?(report, kind)
      refute Map.has_key?(report, if(kind == "songs", do: "courses", else: "songs"))
      text = capture_io(fn -> assert Cli.run(args) == 0 end)
      assert text =~ if(kind == "songs", do: "Songs\n ID", else: "Courses\n ID")
      refute text =~ if(kind == "songs", do: "Courses\n ID", else: "Songs\n ID")
    end

    course = json_result(["inspect", input, "--kind", "courses", "--id", "-1", "--json"], 0)
    assert course["course_id"] == -1
  end

  test "edits require an instruction and report unchanged values", %{input: input} do
    args = ["edit", input, "--id", "1120", "--dry-run", "--json"]
    assert hd(json_result(args, 2)["errors"])["code"] == "usage"
    assert json_result(args ++ ["--set", "bpm=120"], 0)["unchanged"]
    refute json_result(args ++ ["--set", "bpm=150"], 0)["unchanged"]

    assert capture_io(fn ->
             assert Cli.run(["edit", input, "--id", "1120", "--set", "bpm=120", "--dry-run"]) == 0
           end) =~ "No record values changed."
  end
end
