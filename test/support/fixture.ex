defmodule GfdmMdb.Fixture do
  @moduledoc false

  alias GfdmMdb.{Database, Schema}

  def read(path, opts \\ []) do
    path |> File.read!() |> GfdmMdb.decode(opts)
  end

  def write(database, path, opts \\ []) do
    {:ok, bytes} = GfdmMdb.encode(database, opts)
    File.write!(path, bytes)
  end

  def database(format \\ 102, version \\ nil) do
    database = Database.new(format, version)

    song =
      Schema.template(Schema.song_fields(format, version))
      |> Map.merge(%{
        "music_id" => 1120,
        "title_ascii" => "WHITE ｔORNADO",
        "bpm" => 120,
        "guitar_offset" => -128,
        "drum_offset" => 127
      })

    course =
      Schema.template(Schema.course_fields())
      |> Map.merge(%{
        "course_id" => -1,
        "music_ids" => List.duplicate(1120, 4),
        "course_flag" => 2_147_483_651
      })

    %{database | songs: [song], courses: [course]}
  end
end
