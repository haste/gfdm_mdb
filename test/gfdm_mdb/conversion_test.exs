defmodule GfdmMdb.ConversionTest do
  use ExUnit.Case, async: true

  alias GfdmMdb.Fixture

  test "v5 to v6 fills self sequence references and reports every automatic value" do
    source = Fixture.database(203, 5)
    source = %{source | songs: source.songs ++ [Map.put(hd(source.songs), "music_id", 2000)]}

    assert %{errors: [], database: target, reports: %{conversion: report}} =
             GfdmMdb.transform(source, "convert", target: {203, 6})

    assert Enum.map(target.songs, &{&1["seq_id"], &1["is_classic_seq"]}) == [{1120, 0}, {2000, 0}]

    assert Map.new(report.issues, &{{&1.record_id, &1.path}, {&1.kind, &1.value}}) == %{
             {1120, "songs.seq_id"} => {:filled, 1120},
             {1120, "songs.is_classic_seq"} => {:filled, 0},
             {2000, "songs.seq_id"} => {:filled, 2000},
             {2000, "songs.is_classic_seq"} => {:filled, 0}
           }
  end

  test "display titles fall back to the stored title without replacing supplied metadata" do
    source = Fixture.database(202)
    defaults = %{"first_classic_ver" => [1, 2]}

    assert %{errors: [], database: target, reports: %{conversion: %{issues: [issue]}}} =
             GfdmMdb.transform(source, "convert", target: {203, 1}, defaults: defaults)

    assert hd(target.songs)["title_name"] == hd(source.songs)["title_ascii"]
    assert issue.kind == :filled
    assert issue.path == "songs.title_name"

    for options <- [
          [defaults: Map.put(defaults, "title_name", "Display title")],
          [defaults: defaults, overrides: %{"1120" => %{"title_name" => "Display title"}}]
        ] do
      assert %{errors: [], database: target, reports: %{conversion: %{issues: []}}} =
               GfdmMdb.transform(source, "convert", [target: {203, 1}] ++ options)

      assert hd(target.songs)["title_name"] == "Display title"
    end
  end

  test "region expansion preserves existing entries and respects overrides" do
    source = Fixture.database(203, 2)
    source = %{source | songs: [Map.put(hd(source.songs), "disable_area", [7, 255])]}

    assert %{errors: [], database: target, reports: %{conversion: %{issues: [issue]}}} =
             GfdmMdb.transform(source, "convert",
               target: {203, 3},
               defaults: %{"type_category" => 0}
             )

    assert hd(target.songs)["disable_area"] == [7, 255, 0]
    assert issue.kind == :filled
    assert issue.value == [7, 255, 0]

    assert %{errors: [], database: overridden, reports: %{conversion: %{issues: []}}} =
             GfdmMdb.transform(source, "convert",
               target: {203, 3},
               defaults: %{"type_category" => 0},
               overrides: %{"1120" => %{"disable_area" => [1, 2, 3]}}
             )

    assert hd(overridden.songs)["disable_area"] == [1, 2, 3]
  end

  test "automatic fills honor existing values and explicit overrides including invalid ones" do
    source = Fixture.database(203, 5)

    for replacement <- [0, 1234] do
      assert %{errors: [], database: target, reports: %{conversion: %{issues: []}}} =
               GfdmMdb.transform(source, "convert",
                 target: {203, 6},
                 defaults: %{"seq_id" => replacement, "is_classic_seq" => 1}
               )

      assert hd(target.songs)["seq_id"] == replacement
    end

    assert %{errors: [%{code: :conversion}], reports: %{conversion: %{issues: issues}}} =
             GfdmMdb.transform(source, "convert",
               target: {203, 6},
               overrides: %{"1120" => %{"seq_id" => 2_147_483_648, "is_classic_seq" => 1}}
             )

    assert Enum.any?(issues, &(&1.kind == :incompatible and &1.path == "songs.seq_id"))

    assert %{errors: [%{code: :conversion}], reports: %{conversion: %{issues: issues}}} =
             GfdmMdb.transform(source, "convert",
               target: {203, 6},
               defaults: %{"is_classic_seq" => 1}
             )

    assert Enum.any?(issues, &(&1.kind == :missing and &1.path == "songs.seq_id"))
  end
end
