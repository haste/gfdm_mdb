defmodule GfdmMdb.JsonTest do
  use ExUnit.Case, async: true

  alias GfdmMdb.Codec.{Cipher, Json}
  alias GfdmMdb.{Database, Fixture, Schema}

  @schemas [{100, nil}, {101, nil}, {102, nil}, {202, nil}] ++ Enum.map(1..6, &{203, &1})
  @classic %{
    "guitar" => %{"beginner" => 0, "basic" => 16, "advanced" => 33, "extreme" => 99},
    "bass" => %{"beginner" => 0, "basic" => 20, "advanced" => 40, "extreme" => 0},
    "open" => %{"beginner" => 0, "basic" => 20, "advanced" => 37, "extreme" => 52},
    "drum" => %{"beginner" => 0, "basic" => 18, "advanced" => 37, "extreme" => 255}
  }
  @modern %{
    "guitar" => %{
      "novice" => 0,
      "basic" => 101,
      "advanced" => 202,
      "extreme" => 303,
      "master" => 404
    },
    "drum" => %{
      "novice" => 0,
      "basic" => 505,
      "advanced" => 606,
      "extreme" => 707,
      "master" => 808
    },
    "bass" => %{
      "novice" => 0,
      "basic" => 909,
      "advanced" => 1010,
      "extreme" => 1111,
      "master" => 65_535
    }
  }

  test "every schema round trips named records and preserved metadata without changing native bytes" do
    names =
      @schemas
      |> Enum.flat_map(fn {format, version} -> Schema.song_fields(format, version) end)
      |> Enum.map(& &1.name)
      |> Enum.uniq()
      |> Enum.sort()

    for {format, version} <- @schemas do
      database = Fixture.database(format, version)
      song = hd(database.songs) |> put_in(["difficulty", "classic"], @classic)

      song =
        if Map.has_key?(song["difficulty"], "modern"),
          do: put_in(song, ["difficulty", "modern"], @modern),
          else: song

      song = Map.put(song, "b_long", if(format == 203, do: 1, else: 254))
      database = %{database | songs: [song], identity: "test-release"}

      database =
        if format == 203 do
          %{database | header: %{"checksum" => -1}}
        else
          %{
            database
            | encrypted: true,
              header: Map.put(database.header, "reserved", "AB" <> String.duplicate("00", 37))
          }
        end

      assert {:ok, bytes} = GfdmMdb.encode(database)
      assert_native_difficulties(bytes, format)
      assert {:ok, json} = GfdmMdb.encode(database, encoding: :json)
      assert {:ok, decoded} = GfdmMdb.decode(json)
      assert {:ok, ^bytes} = GfdmMdb.encode(decoded)

      envelope = JSON.decode!(json)
      assert decoded.songs == envelope["songs"]
      assert decoded.identity == "test-release"
      assert Enum.sort(Map.keys(envelope)) == ~w(courses identity json_version native songs)
      assert envelope["json_version"] == 1
      assert envelope["native"]["format"] == format
      assert envelope["native"]["schema_version"] == version
      assert envelope["identity"] == "test-release"

      [exported] = envelope["songs"]

      assert Enum.sort(Map.keys(exported)) == names

      for name <- names -- Map.keys(song), do: assert(exported[name] == nil)

      assert Map.keys(exported["difficulty"]) |> Enum.sort() == ["classic", "modern"]
      assert envelope["courses"] == database.courses
      assert envelope["native"]["header"] == database.header
    end
  end

  test "manual record additions and removals preserve order and derive native counts" do
    for {format, version} <- [{102, nil}, {203, 6}] do
      envelope = Fixture.database(format, version) |> Json.envelope()
      song = hd(envelope["songs"])

      edited =
        envelope
        |> Map.put("songs", [Map.put(song, "music_id", 2000), song])
        |> Map.put("courses", [])

      assert {:ok, database} = edited |> Json.pretty() |> GfdmMdb.decode()
      assert Enum.map(database.songs, & &1["music_id"]) == [2000, 1120]
      assert Database.header(database)["record_count"] == 2
      assert Database.header(database)["course_count"] == 0
      assert {:ok, bytes} = GfdmMdb.encode(database)
      assert {:ok, native} = GfdmMdb.decode(bytes)
      assert Json.envelope(native) == Json.envelope(database)

      empty = envelope |> Map.put("songs", []) |> Map.put("courses", [])
      assert {:ok, database} = empty |> Json.pretty() |> GfdmMdb.decode()
      assert database.schema_version == version
      assert Database.header(database)["record_count"] == 0
    end
  end

  test "invalid JSON metadata and record collections identify the offending field" do
    envelope = Fixture.database(203, 6) |> Json.envelope()

    for {invalid, path} <- [
          {Map.put(envelope, "json_version", 999), "json_version"},
          {Map.put(envelope, "typo", 1), ""},
          {Map.put(envelope, "native", nil), "native"},
          {put_in(envelope, ["native", "format"], 203.0), "native.format"},
          {put_in(envelope, ["native", "schema_version"], 7), "native.format"},
          {put_in(envelope, ["native", "encrypted"], true), "native.encrypted"},
          {put_in(envelope, ["native", "header"], nil), "native.header"},
          {put_in(envelope, ["native", "header"], %{}), "native.header.checksum"},
          {put_in(envelope, ["native", "header", "checksum"], 4_294_967_295),
           "native.header.checksum"},
          {Map.put(envelope, "identity", 123), "identity"},
          {Map.put(envelope, "songs", %{}), "songs"},
          {Map.put(envelope, "courses", nil), "courses"},
          {Map.put(envelope, "songs", [nil]), "songs"},
          {Map.put(envelope, "songs", envelope["songs"] ++ envelope["songs"]), "songs.music_id"}
        ] do
      assert {:error, %{path: ^path}} = invalid |> JSON.encode!() |> GfdmMdb.decode()
    end
  end

  test "BOM-prefixed envelopes and record patches decode with normal validation" do
    database = Fixture.database()
    assert {:ok, json} = GfdmMdb.encode(database, encoding: :json)
    bytes = <<0xEF, 0xBB, 0xBF>> <> json

    assert {:ok, decoded} = GfdmMdb.decode(bytes)
    assert Json.envelope(decoded) == Json.envelope(database)
    assert {:ok, %{"bpm" => 150}} = Json.parse(<<0xEF, 0xBB, 0xBF>> <> ~s({"bpm":150}))

    assert {:error, %{code: :duplicate_key}} =
             Json.parse(<<0xEF, 0xBB, 0xBF>> <> ~s({"bpm":150,"bpm":160}))

    assert {:error, %{code: :json}} = GfdmMdb.decode(bytes <> " garbage")
  end

  test "named difficulties validate complete supplied families and reject unknown names and values" do
    database = Fixture.database(203, 6)
    record = hd(database.songs)

    for invalid <- [
          Map.put(record, "typo", 0),
          Map.delete(record, "bpm"),
          Map.put(record, "difficulty", nil),
          update_in(record, ["difficulty", "classic"], &Map.delete(&1, "open")),
          put_in(record, ["difficulty", "modern", "open"], %{}),
          put_in(record, ["difficulty", "classic", "guitar", "master"], 99),
          put_in(record, ["difficulty", "classic", "guitar", "basic"], 256),
          put_in(record, ["difficulty", "modern", "guitar", "basic"], 65_536),
          put_in(record, ["difficulty", "modern", "guitar", "basic"], -1),
          put_in(record, ["difficulty", "modern", "guitar", "basic"], 1.5),
          put_in(record, ["difficulty", "modern", "guitar", "basic"], "101")
        ] do
      assert {:error, _error} =
               database
               |> Json.envelope()
               |> Map.put("songs", [invalid])
               |> Json.pretty()
               |> GfdmMdb.decode()
    end

    classic_database = Fixture.database()
    classic = hd(classic_database.songs)
    mixed = put_in(classic, ["difficulty", "modern"], record["difficulty"]["modern"])

    assert {:ok, decoded} =
             classic_database
             |> Json.envelope()
             |> Map.put("songs", [mixed])
             |> JSON.encode!()
             |> GfdmMdb.decode()

    assert hd(decoded.songs) == mixed
    assert {:error, %{code: :unknown_field}} = GfdmMdb.encode(decoded)
  end

  test "JSON accepts newer and older records independently of native metadata" do
    for {{source_format, source_version}, {format, version}} <- [
          {{100, nil}, {203, 6}},
          {{203, 6}, {100, nil}}
        ] do
      envelope = Fixture.database(source_format, source_version) |> Json.envelope()
      song = hd(Fixture.database(format, version).songs)

      assert {:ok, decoded} =
               envelope |> Map.put("songs", [song]) |> Json.pretty() |> GfdmMdb.decode()

      assert hd(decoded.songs) == song
    end
  end

  test "JSON stores native type variants until explicit target conversion validates them" do
    envelope = Fixture.database(100) |> Json.envelope()
    [song] = envelope["songs"]

    song =
      Map.merge(song, %{
        "seq_flag" => 65_535,
        "pad_diff" => 65_535,
        "category_kana" => -128,
        "modern_movie_disp_id" => -1,
        "disable_area" => [1, 2, 3],
        "title_name" => "Long display title",
        "data_ver" => 119
      })

    assert {:ok, decoded} =
             envelope |> Map.put("songs", [song]) |> Json.pretty() |> GfdmMdb.decode()

    assert {:ok, json} = GfdmMdb.encode(decoded, encoding: :json)
    assert {:ok, ^decoded} = GfdmMdb.decode(json)
    assert {:error, _error} = GfdmMdb.encode(decoded)

    assert %{errors: [%{code: :conversion}], reports: %{conversion: %{issues: issues}}} =
             GfdmMdb.transform(decoded, "convert", target: {100, nil}, allow_loss: true)

    assert Enum.any?(issues, &(&1.kind == :incompatible and &1.path == "songs.seq_flag"))
    assert Enum.any?(issues, &(&1.kind == :removed and &1.path == "songs.data_ver"))

    for {name, value} <- [
          {"typo", nil},
          {"bpm", nil},
          {"seq_flag", 65_536},
          {"category_kana", 256},
          {"modern_movie_disp_id", -129},
          {"disable_area", [0]},
          {"data_ver", "119"}
        ] do
      invalid = Map.put(song, name, value)

      assert {:error, _error} =
               envelope |> Map.put("songs", [invalid]) |> Json.pretty() |> GfdmMdb.decode()
    end
  end

  test "null version fields stay missing for native conversion and defaults can fill them" do
    envelope = Fixture.database(203, 4) |> Json.envelope()
    assert hd(envelope["songs"])["data_ver"] == nil
    assert {:ok, decoded} = envelope |> Json.pretty() |> GfdmMdb.decode()

    assert %{
             errors: [%{code: :conversion}],
             reports: %{conversion: %{issues: [%{kind: :missing, path: "songs.data_ver"}]}}
           } =
             GfdmMdb.transform(decoded, "convert", target: {203, 5})

    assert %{errors: [], database: target} =
             GfdmMdb.transform(decoded, "convert",
               target: {203, 5},
               defaults: %{"data_ver" => 119}
             )

    assert hd(target.songs)["data_ver"] == 119
  end

  defp assert_native_difficulties(xml, 203) do
    assert xml =~
             ~s(<classics_diff_list __type="u8" __count="16">0 16 33 99 0 20 40 0 0 20 37 52 0 18 37 255</classics_diff_list>)

    assert xml =~
             ~s(<xg_diff_list __type="u16" __count="15">0 101 202 303 404 0 505 606 707 808 0 909 1010 1111 65535</xg_diff_list>)
  end

  defp assert_native_difficulties(encrypted, format) do
    bytes = Cipher.decrypt(encrypted)

    assert binary_part(bytes, 68, 16) ==
             <<0, 16, 33, 99, 0, 20, 40, 0, 0, 20, 37, 52, 0, 18, 37, 255>>

    if format == 202 do
      assert binary_part(bytes, 84, 30) ==
               Base.decode16!("00006500CA002F0194010000F9015E02C302280300008D03F2035704FFFF")
    end
  end
end
