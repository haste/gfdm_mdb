defmodule GfdmMdb.Schema do
  @moduledoc "Canonical record schemas, native constraints, storage order and header defaults."

  alias GfdmMdb.{Difficulty, Result, Schema}
  alias GfdmMdb.Schema.Field

  @type format :: 100 | 101 | 102 | 202 | 203
  @type version :: 1..6 | nil

  @spec validate(term(), term()) :: :ok | {:error, Result.diagnostic()}
  def validate(format, version \\ nil) do
    cond do
      format === 203 and version in 1..6 ->
        :ok

      format in [100, 101, 102, 202] and version == nil ->
        :ok

      true ->
        {:error,
         Result.diagnostic(
           :schema,
           "native.format",
           "Unsupported format/schema: #{inspect(format)}:#{inspect(version)}"
         )}
    end
  end

  @spec song_fields(format(), version()) :: [Schema.Field.t()]
  def song_fields(format, version \\ nil)
  def song_fields(203, version), do: Schema.Format203.fields(version)
  def song_fields(202, nil), do: Schema.Format202.fields()
  def song_fields(format, nil) when format in [100, 101, 102], do: Schema.Format100.fields(format)

  @spec record_fields(GfdmMdb.Database.t(), GfdmMdb.Database.kind(), atom()) :: [Schema.Field.t()]
  def record_fields(database, kind, encoding \\ :native)
  def record_fields(_database, :songs, :json), do: Schema.Json.song_fields()

  def record_fields(database, :songs, _encoding) do
    song_fields(database.format, database.schema_version)
  end

  def record_fields(_database, :courses, _encoding), do: course_fields()

  @spec id_field(GfdmMdb.Database.kind()) :: String.t()
  def id_field(:songs), do: "music_id"
  def id_field(:courses), do: "course_id"

  @spec course_fields() :: [Schema.Field.t()]
  def course_fields do
    [
      Field.new("course_id", :s32, 1),
      Field.new("course_flag", :u32, 1),
      Field.new("music_ids", :s32, 4),
      difficulty([:classic])
    ]
  end

  @spec header_fields(format()) :: [Schema.Field.t()]
  def header_fields(203) do
    [
      Field.new("id", :s8, 8),
      Field.new("format", :s32, 1),
      Field.new("checksum", :s32, 1),
      Field.new("header_size", :s16, 1),
      Field.new("record_size", :s16, 1),
      Field.new("record_count", :s16, 1),
      Field.new("course_size", :s16, 1),
      Field.new("course_count", :s16, 1)
    ]
  end

  def header_fields(_format) do
    [
      Field.new("id", :hex, 8),
      Field.new("format", :s32, 1),
      Field.new("checksum", :u32, 1),
      Field.new("header_size", :u16, 1),
      Field.new("record_size", :u16, 1),
      Field.new("record_count", :u16, 1),
      Field.new("course_count", :u16, 1),
      Field.new("course_size", :u16, 1),
      Field.new("reserved", :hex, 38)
    ]
  end

  @spec default_header(format()) :: GfdmMdb.Database.record_data()
  def default_header(format) do
    # Binary producer size fields are metadata, not the actual record strides.
    {id, record_size, course_size} =
      if format == 203,
        do: {~c"GF/DMmdb", 300, 40},
        else: {Base.encode16("GF/DMmdb"), 188, 36}

    Map.merge(template(header_fields(format)), %{
      "id" => id,
      "format" => format,
      "header_size" => 64,
      "record_size" => record_size,
      "course_size" => course_size
    })
  end

  @spec native_encoding(format()) :: :binary | :xml
  def native_encoding(203), do: :xml
  def native_encoding(_format), do: :binary

  @spec stride(100 | 101 | 102 | 202) :: pos_integer()
  def stride(format) do
    format |> song_fields() |> width()
  end

  @spec width([Field.t()]) :: non_neg_integer()
  def width(fields), do: Enum.sum_by(fields, &Field.width/1)

  @spec metadata_fields(format()) :: [Field.t()]
  def metadata_fields(format) do
    names =
      if format == 203, do: ~w(checksum), else: ~w(checksum record_size course_size reserved)

    Enum.filter(header_fields(format), &(&1.name in names))
  end

  @spec difficulty([:classic | :modern]) :: Field.t()
  def difficulty(families) do
    Field.object("difficulty", Enum.map(families, &Difficulty.field/1))
  end

  @spec versions() :: [1..6]
  def versions do
    Enum.to_list(1..6)
  end

  @spec template([Schema.Field.t()]) :: GfdmMdb.Database.record_data()
  def template(fields) do
    Map.new(fields, &{&1.name, Schema.Field.neutral(&1)})
  end
end
