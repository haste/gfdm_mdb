defmodule GfdmMdb.Schema.Format100 do
  @moduledoc "The shared ordered binary song layout for formats 100 to 102."

  alias GfdmMdb.Schema.Field

  @spec fields(100 | 101 | 102) :: [Field.t()]
  def fields(format) do
    [
      Field.new("music_id", :s32, 1),
      GfdmMdb.Schema.difficulty([:classic]),
      Field.new("seq_flag", :u8, 1),
      Field.new("pad_diff", :u8, 1),
      Field.new("contain_stat", :u8, 2),
      Field.new("first_classic_ver", :u8, 2),
      Field.new("b_long", :u8, 1),
      Field.new("b_eemall", :u8, 1),
      Field.new("bpm", :u16, 1),
      Field.new("bpm2", :u16, 1),
      Field.new("title_ascii", :title, 16),
      Field.new("order_ascii", :u16, 1),
      Field.new("order_kana", :u16, 1),
      Field.new("category_kana", :u8, 1),
      Field.new("secret", :u8, 2),
      Field.new("b_session", :u8, 1),
      Field.new("speed", :u8, 1),
      Field.new("life", :u8, 1),
      Field.new("guitar_offset", :s8, 1),
      Field.new("drum_offset", :s8, 1),
      Field.new("chart_list", :u8, 128)
    ] ++ extension(format)
  end

  defp extension(100), do: []

  defp extension(format) when format in [101, 102] do
    [
      Field.new("origin", :u8, 1),
      # Preserve these bytes even though their format-101 meaning is unknown.
      Field.new("music_type", :u8, 1),
      Field.new("genre", :u8, 1),
      Field.new("is_remaster", :u8, 1)
    ]
  end
end
