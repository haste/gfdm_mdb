defmodule GfdmMdb.WorkflowTest do
  use ExUnit.Case, async: true
  alias GfdmMdb.{Database, Fixture, Schema, Validation}

  test "add, clone, patch and remove preserve ordering, count records and reject bad IDs/fields" do
    database = Fixture.database()
    original = hd(database.songs)

    assert %{database: cloned, errors: []} =
             GfdmMdb.transform(database, "clone", id: 1120, new_id: 1)

    assert Enum.map(cloned.songs, & &1["music_id"]) == [1, 1120]
    assert Database.header(cloned)["record_count"] == 2

    assert %{errors: [%{code: :duplicate_id}]} =
             GfdmMdb.transform(cloned, "clone", id: 1120, new_id: 1)

    assert %{errors: [%{code: :not_found}]} = GfdmMdb.transform(database, "remove", id: 99)

    assert %{errors: [%{code: :unknown_field}]} =
             GfdmMdb.transform(database, "edit", id: 1120, patch: %{"typo" => 1})

    assert %{errors: [%{code: :invalid_value}]} =
             GfdmMdb.transform(database, "edit", id: 1120, patch: %{"contain_stat" => [1]})

    assert %{database: edited, errors: []} =
             GfdmMdb.transform(database, "edit", id: 1120, patch: %{"contain_stat" => [255, 1]})

    assert hd(edited.songs)["contain_stat"] == [255, 1]
    assert hd(edited.songs)["order_ascii"] == original["order_ascii"]
    assert %{database: removed, errors: []} = GfdmMdb.transform(database, "remove", id: 1120)
    assert Database.header(removed)["record_count"] == 0
    assert removed.courses == database.courses
    unsorted = %{cloned | songs: Enum.reverse(cloned.songs)}

    assert %{database: added, errors: []} =
             GfdmMdb.transform(unsorted, "add", record: Map.put(original, "music_id", 2))

    assert Enum.map(added.songs, & &1["music_id"]) == [1120, 1, 2]

    assert %{database: course_clone, errors: []} =
             GfdmMdb.transform(database, "clone", id: -1, new_id: 2, patch: %{}, kind: :courses)

    assert Database.header(course_clone)["course_count"] == 2
  end

  test "conversion reports required fields, applies defaults and overrides, and prevents loss" do
    database = %{Fixture.database(203, 4) | identity: "mt"}
    defaults = %{"data_ver" => 119, "bpm" => 1, "music_id" => 99}

    assert %{errors: [%{code: :conversion}], reports: %{conversion: report}} =
             GfdmMdb.transform(database, "convert", target: {203, 5})

    assert %{issues: [%{kind: :missing, path: "songs.data_ver"}]} = report

    assert %{database: converted, errors: []} =
             GfdmMdb.transform(database, "convert",
               target: {203, 5},
               defaults: defaults
             )

    assert converted.identity == "mt"
    assert hd(converted.songs) == Map.put(hd(database.songs), "data_ver", 119)

    assert %{database: overridden, errors: []} =
             GfdmMdb.transform(database, "convert",
               target: {203, 5},
               defaults: defaults,
               overrides: %{"1120" => %{"data_ver" => 120, "bpm" => 150}}
             )

    assert hd(overridden.songs) ==
             Map.merge(hd(database.songs), %{"data_ver" => 120, "bpm" => 150})

    assert %{errors: [%{code: :conversion}]} =
             GfdmMdb.transform(converted, "convert", target: {203, 4})

    assert %{database: ^database, errors: [], reports: %{conversion: report}} =
             GfdmMdb.transform(converted, "convert", target: {203, 4}, allow_loss: true)

    assert Enum.any?(report.issues, &(&1.kind == :removed))
  end

  test "conversion fills and removes difficulty families independently" do
    source = Fixture.database(102)
    [song] = source.songs
    song = put_in(song, ["difficulty", "classic", "guitar", "basic"], 99)
    source = %{source | songs: [song]}
    defaults = Schema.song_fields(202) |> Schema.template()
    defaults = put_in(defaults, ["difficulty", "modern", "drum", "master"], 950)

    assert %{errors: [], database: converted} =
             GfdmMdb.transform(source, "convert",
               target: {202, nil},
               defaults: defaults,
               allow_loss: true
             )

    assert hd(converted.songs)["music_id"] == 1120
    assert hd(converted.songs)["difficulty"]["classic"] == song["difficulty"]["classic"]
    assert hd(converted.songs)["difficulty"]["modern"]["drum"]["master"] == 950

    result =
      GfdmMdb.transform(converted, "convert",
        target: {102, nil},
        defaults: %{"first_classic_ver" => [0, 0]}
      )

    assert [%{code: :conversion}] = result.errors

    assert Enum.any?(
             result.reports.conversion.issues,
             &(&1.kind == :removed and &1.path == "songs.difficulty.modern")
           )

    assert %{errors: [], database: restored} =
             GfdmMdb.transform(converted, "convert",
               target: {102, nil},
               defaults: %{"first_classic_ver" => [0, 0]},
               allow_loss: true
             )

    assert restored == source
  end

  test "add rejects invalid records and ID edits cannot introduce duplicates" do
    database = Fixture.database()

    for {record, code} <- [
          {nil, :record},
          {%{}, :missing_field},
          {Map.put(hd(database.songs), "music_id", nil), :invalid_value},
          {hd(database.songs), :duplicate_id}
        ] do
      assert %{errors: [%{code: ^code}]} = GfdmMdb.transform(database, "add", record: record)
    end

    assert %{database: database, errors: []} =
             GfdmMdb.transform(database, "clone", id: 1120, new_id: 2)

    assert %{errors: [%{code: :duplicate_id}]} =
             GfdmMdb.transform(database, "edit", id: 1120, patch: %{"music_id" => 2})

    assert %{database: updated, errors: []} =
             GfdmMdb.transform(database, "edit", id: 1120, patch: %{"music_id" => 3})

    assert Enum.map(updated.songs, & &1["music_id"]) == [2, 3]
  end

  test "record additions reject counts outside the native header range" do
    database = Fixture.database(203, 1)
    course = hd(database.courses)
    courses = for id <- 1..32_767, do: Map.put(course, "course_id", id)
    database = %{database | courses: courses}

    assert %{errors: [%{code: :invalid_value, path: "native.header.course_count"}]} =
             GfdmMdb.transform(database, "clone", id: 1, new_id: 32_768, kind: :courses)
  end

  test "conversion never wraps, truncates arrays or infers version fields" do
    database = Fixture.database(203, 3)

    assert %{database: database, errors: []} =
             GfdmMdb.transform(database, "edit", id: 1120, patch: %{"modern_movie_disp_id" => -1})

    assert %{errors: [%{code: :conversion}]} =
             GfdmMdb.transform(database, "convert", target: {203, 1}, allow_loss: true)

    assert %{database: converted, errors: []} =
             GfdmMdb.transform(database, "convert",
               target: {203, 1},
               allow_loss: true,
               overrides: %{"1120" => %{"modern_movie_disp_id" => 0}}
             )

    assert converted.schema_version == 1
    assert hd(converted.songs)["modern_movie_disp_id"] == 0

    assert %{errors: [%{code: :conversion}]} =
             GfdmMdb.transform(database, "convert", target: {203, 2}, allow_loss: true)

    assert %{errors: [%{code: :conversion}], reports: %{conversion: %{issues: issues}}} =
             GfdmMdb.transform(database, "convert",
               target: {203, 2},
               allow_loss: true,
               defaults: %{"disable_area" => [0, 0]}
             )

    assert Enum.any?(issues, &(&1.kind == :incompatible and &1.path == "songs.disable_area"))

    assert %{database: converted, errors: []} =
             GfdmMdb.transform(database, "convert",
               target: {203, 2},
               allow_loss: true,
               overrides: %{"1120" => %{"disable_area" => [0, 0]}}
             )

    assert converted.schema_version == 2
    assert hd(converted.songs)["disable_area"] == [0, 0]

    assert %{errors: [%{message: message}], reports: %{conversion: %{issues: issues}}} =
             GfdmMdb.transform(Fixture.database(102), "convert",
               target: {202, nil},
               allow_loss: true
             )

    assert message == "Missing target fields require --defaults or --overrides"
    assert Enum.any?(issues, &(&1.path == "songs.first_modern_ver" and &1.kind == :missing))

    assert %{errors: [%{code: :unknown_field}]} =
             GfdmMdb.transform(database, "convert", target: {203, 3}, defaults: %{"typo" => 1})

    assert %{errors: [%{code: :conversion}]} =
             GfdmMdb.transform(database, "convert", target: {203, 3}, overrides: %{"999" => %{}})
  end

  test "reindex replaces full selected rank sets with deterministic ties and explicit kana categories" do
    database = Fixture.database(203, 6)

    assert %{database: database, errors: []} =
             GfdmMdb.transform(database, "clone", id: 1120, new_id: 2)

    assert %{database: database, errors: []} =
             GfdmMdb.transform(database, "clone", id: 1120, new_id: 3)

    database = %{database | songs: Enum.reverse(database.songs)}

    keys = %{
      "1120" => %{
        "title" => %{"ascii" => "A", "kana" => "ア", "category" => "A"},
        "artist" => %{"ascii" => "Shared"}
      },
      "2" => %{"title" => %{"ascii" => "A"}, "artist" => %{"ascii" => "Shared"}},
      "3" => %{"title" => %{"ascii" => "B"}, "artist" => %{"ascii" => "Different"}}
    }

    assert %{database: indexed, errors: []} =
             GfdmMdb.transform(database, "reindex", keys: keys, select: :both)

    assert Enum.map(indexed.songs, & &1["music_id"]) == [1120, 3, 2]
    by_id = Map.new(indexed.songs, &{&1["music_id"], &1})
    assert by_id[2]["order_ascii"] == 1
    assert by_id[1120]["order_ascii"] == 2
    assert by_id[3]["order_ascii"] == 3
    assert by_id[1120]["order_kana"] == 1
    assert by_id[1120]["category_kana"] == 65
    assert by_id[2]["order_kana"] == 0
    assert by_id[2]["category_kana"] == 0
    assert by_id[1120]["artist_order_ascii"] == by_id[2]["artist_order_ascii"]

    assert %{database: ^indexed, errors: []} =
             GfdmMdb.transform(indexed, "reindex", keys: keys, select: :both)

    assert %{errors: [%{code: :sort_keys}]} = GfdmMdb.transform(database, "reindex", keys: %{})

    assert %{errors: [%{code: :sort_keys}]} =
             GfdmMdb.transform(Fixture.database(), "reindex",
               keys: %{},
               select: :artist,
               use_stored_keys: true
             )

    assert %{database: empty, errors: []} =
             GfdmMdb.transform(Database.new(102), "reindex", keys: %{})

    assert empty.songs == []
  end

  test "stored artist strings get distinct ranks and preserve unselected title ranks" do
    database = Fixture.database(203, 6)
    title_ranks = %{"order_ascii" => 7, "order_kana" => 8, "category_kana" => 65}
    database = %{database | songs: [Map.merge(hd(database.songs), title_ranks)]}

    assert %{database: database, errors: []} =
             GfdmMdb.transform(database, "clone", id: 1120, new_id: 2)

    assert %{database: indexed, errors: []} =
             GfdmMdb.transform(database, "reindex",
               keys: %{},
               select: :artist,
               use_stored_keys: true
             )

    assert Enum.map(indexed.songs, & &1["artist_order_ascii"]) == [1, 2]

    assert Enum.map(indexed.songs, &Map.take(&1, ~w(order_ascii order_kana category_kana))) ==
             [title_ranks, title_ranks]
  end

  test "reference warnings identify each missing song once per course" do
    database = Fixture.database()

    assert %{database: database, errors: []} =
             GfdmMdb.transform(database, "edit",
               id: -1,
               patch: %{"music_ids" => [7, 7, 8, 8]},
               kind: :courses
             )

    assert %{database: database, errors: []} =
             GfdmMdb.transform(database, "clone", id: -1, new_id: 2, patch: %{}, kind: :courses)

    report = Validation.verify(database)
    references = Enum.filter(report.warnings, &(&1.code == :reference))

    assert Enum.map(references, &{&1.record_id, &1.message}) == [
             {-1, "Song 7 is absent. Sequence assets have not been checked"},
             {-1, "Song 8 is absent. Sequence assets have not been checked"},
             {2, "Song 7 is absent. Sequence assets have not been checked"},
             {2, "Song 8 is absent. Sequence assets have not been checked"}
           ]

    assert report.valid
    refute Validation.verify(database, strict: true).valid
  end

  test "reindex rejects categories without kana instead of discarding them" do
    database = Fixture.database(203, 6)

    for group <- ["title", "artist"] do
      keys = %{"1120" => %{group => %{"ascii" => "A", "category" => "A"}}}
      selection = if group == "title", do: :title, else: :artist

      assert %{errors: [%{path: path, record_id: 1120}]} =
               GfdmMdb.transform(database, "reindex", keys: keys, select: selection)

      assert path == group <> ".category"
    end
  end
end
