defmodule GfdmMdb.Schema.Format203 do
  @moduledoc "The ordered XML song layout for format 203, versions 1 to 6."

  alias GfdmMdb.Schema.Field

  @spec fields(1..6) :: [Field.t()]
  def fields(version) when version in 1..6 do
    [
      Field.new("music_id", :s32, 1),
      GfdmMdb.Schema.difficulty([:classic, :modern]),
      Field.new("pad_diff", :u16, 1),
      Field.new("seq_flag", :u16, 1),
      Field.new("modern_seq_flag", :u16, 1),
      Field.new("contain_stat", :u8, 2),
      Field.new("first_modern_ver", :u8, 2),
      Field.new("first_classic_ver", :u8, 2),
      Field.new("b_long", :bool, 1),
      Field.new("b_eemall", :bool, 1),
      Field.new("bpm", :u16, 1),
      Field.new("bpm2", :u16, 1),
      Field.new("title_ascii", :str, 1),
      Field.new("order_ascii", :u16, 1),
      Field.new("order_kana", :u16, 1),
      Field.new("category_kana", :s8, 1)
    ] ++ artist_fields(version) ++ song_fields(version) ++ extension(version)
  end

  defp artist_fields(version) when version < 4, do: []

  defp artist_fields(_version) do
    [
      Field.new("artist_title_ascii", :str, 1),
      Field.new("artist_order_ascii", :u16, 1),
      Field.new("artist_order_kana", :u16, 1),
      Field.new("artist_category_kana", :s8, 1)
    ]
  end

  defp song_fields(version) do
    [
      Field.new("secret", :u8, 2),
      Field.new("modern_secret", :u8, 2),
      Field.new("b_session", :bool, 1),
      Field.new("modern_b_session", :bool, 1),
      Field.new("speed", :u8, 1),
      Field.new("life", :u8, 1),
      Field.new("guitar_offset", :s8, 1),
      Field.new("drum_offset", :s8, 1),
      Field.new("chart_list", :u8, 128),
      Field.new("origin", :u8, 1),
      Field.new("music_type", :u8, 1),
      Field.new("genre", :u8, 1),
      Field.new("modern_active_effect_type", :u8, 1),
      Field.new("modern_movie_disp_type", :u8, 1),
      # XML v2 and later need signed storage to preserve the -1 sentinel.
      Field.new("modern_movie_disp_id", if(version == 1, do: :u8, else: :s8), 1),
      Field.new("is_remaster", :u8, 1),
      Field.new("title_name", :str, 1)
    ]
  end

  defp extension(1), do: []

  defp extension(version) do
    [
      Field.new("license_disp", :u8, 1),
      Field.new("default_music", :u8, 2),
      Field.new("disable_area", :u8, if(version == 2, do: 2, else: 3))
    ] ++
      if(version >= 3, do: [Field.new("type_category", :u32, 1)], else: []) ++
      if(version >= 5, do: [Field.new("data_ver", :u16, 1)], else: []) ++
      if(version >= 6,
        do: [Field.new("seq_id", :s32, 1), Field.new("is_classic_seq", :u8, 1)],
        else: []
      )
  end
end
