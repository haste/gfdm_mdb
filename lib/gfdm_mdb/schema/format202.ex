defmodule GfdmMdb.Schema.Format202 do
  @moduledoc "The ordered binary song layout for format 202."

  alias GfdmMdb.Schema.Field

  @spec fields() :: [Field.t()]
  def fields do
    [
      Field.new("music_id", :s32, 1),
      GfdmMdb.Schema.difficulty([:classic, :modern]),
      Field.new("pad_diff", :u16, 1),
      Field.new("seq_flag", :u16, 1),
      Field.new("modern_seq_flag", :u16, 1),
      Field.new("contain_stat", :u8, 2),
      Field.new("first_modern_ver", :u8, 2),
      Field.new("b_long", :u8, 1),
      Field.new("b_eemall", :u8, 1),
      Field.new("bpm", :u16, 1),
      Field.new("bpm2", :u16, 1),
      Field.new("title_ascii", :title, 16),
      Field.new("order_ascii", :u16, 1),
      Field.new("order_kana", :u16, 1),
      Field.new("category_kana", :u8, 1),
      Field.new("secret", :u8, 2),
      Field.new("modern_secret", :u8, 2),
      Field.new("b_session", :u8, 1),
      Field.new("modern_b_session", :u8, 1),
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
      Field.new("modern_movie_disp_id", :u8, 1),
      Field.new("is_remaster", :u8, 1)
    ]
  end
end
