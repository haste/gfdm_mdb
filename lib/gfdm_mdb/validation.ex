defmodule GfdmMdb.Validation do
  @moduledoc "Structural validation and compatibility warnings for MDB records."

  alias GfdmMdb.{Database, Result, Schema}
  alias GfdmMdb.Schema.Field

  @type report :: %{
          valid: boolean(),
          errors: [Result.diagnostic()],
          warnings: [Result.diagnostic()]
        }

  @spec verify(term(), keyword()) :: report()
  def verify(database, opts \\ []) do
    case validate(database, Keyword.get(opts, :encoding, :native)) do
      :ok ->
        compatibility_report(database, opts)

      {:error, error} ->
        %{valid: false, errors: [error], warnings: []}
    end
  end

  @doc """
  Builds a compatibility report for a structurally valid database.

  Call `validate/1` first, or use `verify/2` to include structural validation.
  With `:strict`, compatibility warnings make the report invalid.
  """
  @spec compatibility_report(Database.t(), keyword()) :: report()
  def compatibility_report(%Database{} = database, opts \\ []) do
    warnings = warnings(database)

    %{
      valid: not Keyword.get(opts, :strict, false) or warnings == [],
      errors: [],
      warnings: warnings
    }
  end

  defp identity(value) do
    check(
      value == nil or (is_binary(value) and String.valid?(value)),
      :metadata,
      "identity",
      "Expected a valid UTF-8 string or null"
    )
  end

  @doc "Checks a separate wire header and constructs a database containing only variable metadata."
  @spec decode(map(), Database.record_data()) :: GfdmMdb.result(Database.t())
  def decode(attributes, header) do
    with :ok <- Schema.validate(attributes.format, attributes[:schema_version]),
         fields = Schema.header_fields(attributes.format),
         :ok <- validate_record(header, fields, "native.header"),
         names = Enum.map(Schema.metadata_fields(attributes.format), & &1.name),
         database = struct!(Database, Map.put(attributes, :header, Map.take(header, names))),
         :ok <- validate(database),
         expected = Database.header(database),
         :ok <- each(fields, &fixed(header, &1.name, expected[&1.name])) do
      {:ok, database}
    end
  end

  @spec validate(term(), atom()) :: :ok | {:error, Result.diagnostic()}
  def validate(database, encoding \\ :native)

  def validate(%Database{} = database, encoding) do
    with :ok <- Schema.validate(database.format, database.schema_version),
         :ok <- identity(database.identity),
         :ok <- encryption(database),
         :ok <-
           validate_record(
             database.header,
             Schema.metadata_fields(database.format),
             "native.header"
           ),
         :ok <-
           records(
             database.songs,
             Schema.record_fields(database, :songs, encoding),
             "songs",
             "music_id"
           ),
         :ok <- records(database.courses, Schema.course_fields(), "courses", "course_id") do
      validate_record(
        Database.header(database),
        Schema.header_fields(database.format),
        "native.header"
      )
    end
  end

  def validate(_value, _encoding) do
    {:error, Result.diagnostic(:database, "", "Expected a Database struct")}
  end

  @spec encryption(Database.t()) :: :ok | {:error, Result.diagnostic()}
  def encryption(database) do
    with :ok <-
           check(
             database.encrypted in [true, false],
             :metadata,
             "native.encrypted",
             "Expected boolean"
           ) do
      check(
        database.format != 203 or database.encrypted == false,
        :metadata,
        "native.encrypted",
        "XML cannot be MDBE encrypted"
      )
    end
  end

  @spec validate_record(term(), [Field.t()], String.t(), integer() | nil) ::
          :ok | {:error, Result.diagnostic()}
  def validate_record(record, fields, path, id \\ nil)

  def validate_record(record, fields, path, id) when is_map(record) do
    names = Enum.map(fields, & &1.name)
    unknown = Map.keys(record) -- names

    with :ok <-
           check(
             unknown == [],
             :unknown_field,
             path,
             "Unknown fields: #{inspect(unknown)}",
             id
           ) do
      each(fields, &record_field(record, &1, path, id))
    end
  end

  def validate_record(_record, _fields, path, id) do
    {:error, Result.diagnostic(:record, path, "Expected an object", id)}
  end

  @doc "Validates supplied fields. Each supplied difficulty family must be complete."
  @spec validate_patch(term(), [Field.t()], String.t(), integer() | nil) ::
          :ok | {:error, Result.diagnostic()}
  def validate_patch(record, fields, path, id \\ nil)

  def validate_patch(record, fields, path, id) when is_map(record) do
    names = Enum.map(fields, & &1.name)
    unknown = Map.keys(record) -- names

    with :ok <-
           check(unknown == [], :unknown_field, path, "Unknown fields: #{inspect(unknown)}", id) do
      fields
      |> Enum.filter(&Map.has_key?(record, &1.name))
      |> each(&patch_field(record, &1, path, id))
    end
  end

  def validate_patch(_record, _fields, path, id) do
    {:error, Result.diagnostic(:record, path, "Expected an object", id)}
  end

  ###
  ### Helpers
  ###

  defp patch_field(record, %{name: "difficulty", fields: fields}, path, id) do
    validate_patch(record["difficulty"], fields, path <> ".difficulty", id)
  end

  defp patch_field(record, field, path, id), do: record_field(record, field, path, id)

  defp record_field(record, %{optional: true} = field, path, id) do
    if Map.has_key?(record, field.name),
      do: Field.validate(field, record[field.name], path <> "." <> field.name, id),
      else: :ok
  end

  defp record_field(record, field, path, id) do
    field_path = path <> "." <> field.name

    with :ok <-
           check(
             Map.has_key?(record, field.name),
             :missing_field,
             field_path,
             "Required field is missing",
             id
           ) do
      Field.validate(field, record[field.name], field_path, id)
    end
  end

  defp records(records, fields, path, id_field) do
    with :ok <- check(is_list(records), :records, path, "Expected an array of records"),
         :ok <- each(records, &identified_record(&1, fields, path, id_field)) do
      duplicate_ids(records, path, id_field)
    end
  end

  defp identified_record(record, fields, path, id_field) do
    id = if is_map(record), do: record[id_field]
    validate_record(record, fields, path, id)
  end

  defp duplicate_ids(records, path, id_field) do
    duplicate =
      records
      |> Enum.frequencies_by(& &1[id_field])
      |> Enum.find(fn {_id, count} -> count > 1 end)

    case duplicate do
      nil ->
        :ok

      {id, _count} ->
        {:error,
         Result.diagnostic(:duplicate_id, path <> "." <> id_field, "Duplicate ID #{id}", id)}
    end
  end

  defp fixed(header, field, expected) do
    check(
      header[field] == expected,
      :header,
      "native.header." <> field,
      "Expected #{inspect(expected)}, got #{inspect(header[field])}"
    )
  end

  defp warnings(database) do
    ids = MapSet.new(database.songs, & &1["music_id"])
    song_warnings = Enum.flat_map(database.songs, &song_warnings(&1, database.format, ids))

    course_warnings =
      for course <- database.courses,
          id <- Enum.uniq(course["music_ids"]),
          not MapSet.member?(ids, id) do
        warning(
          :reference,
          "courses.music_ids",
          course["course_id"],
          "Song #{id} is absent. Sequence assets have not been checked"
        )
      end

    song_warnings ++ course_warnings ++ order_warnings(database) ++ header_warnings(database)
  end

  defp song_warnings(song, format, ids) do
    id = song["music_id"]

    checks = [
      {song["bpm2"] > 0 and song["bpm2"] < song["bpm"], :bpm, "bpm2",
       "Maximum BPM is below minimum BPM"},
      {song["pad_diff"] != 0, :reserved, "pad_diff", "Reserved producer field is nonzero"},
      {Enum.with_index(song["chart_list"])
       |> Enum.any?(fn {value, index} -> rem(index, 8) in [6, 7] and value != 0 end), :reserved,
       "chart_list", "Reserved metric bytes are nonzero"},
      {song["is_classic_seq"] not in [nil, 0] and not MapSet.member?(ids, song["seq_id"]),
       :reference, "seq_id",
       "Sequence source is absent from this database. Assets have not been checked"}
    ]

    warnings =
      for {true, code, field, message} <- checks do
        warning(code, "songs." <> field, id, message)
      end

    warnings ++ title_warnings(song, format) ++ marker_warnings(song)
  end

  defp marker_warnings(song) do
    for field <- [
          "b_long",
          "b_eemall",
          "b_session",
          "modern_b_session",
          "is_remaster",
          "license_disp"
        ],
        song[field] != nil,
        song[field] not in [0, 1] do
      warning(
        :marker,
        "songs." <> field,
        song["music_id"],
        "Observed boolean marker contains a value outside 0/1"
      )
    end
  end

  defp title_warnings(song, 203) do
    for {field, maximum} <- [{"title_ascii", 15}, {"artist_title_ascii", 15}, {"title_name", 95}],
        is_binary(song[field]),
        byte_size(song[field]) > maximum do
      warning(
        :compatibility,
        "songs." <> field,
        song["music_id"],
        "Exceeds examined modern runtime capacity of #{maximum} UTF-8 bytes. Historical capacities are not established"
      )
    end
  end

  defp title_warnings(_song, _format) do
    []
  end

  defp order_warnings(database) do
    for {records, id, path} <- [
          {database.songs, "music_id", "songs"},
          {database.courses, "course_id", "courses"}
        ],
        values = Enum.map(records, & &1[id]),
        values != Enum.sort(values) do
      warning(:order, path, nil, "Records are not ordered by ID")
    end
  end

  defp header_warnings(database) do
    expected = Schema.default_header(database.format)

    fields =
      if database.format == 203,
        do: ["checksum"],
        else: ~w(checksum reserved record_size course_size)

    for field <- fields, database.header[field] != expected[field] do
      warning(
        :header,
        "native.header." <> field,
        nil,
        "Value differs from examined producer files"
      )
    end
  end

  defp warning(code, path, id, message) do
    Result.diagnostic(code, path, message, id)
  end

  @spec check(boolean(), atom(), String.t(), String.t(), integer() | nil) ::
          :ok | {:error, Result.diagnostic()}
  def check(condition, code, path, message, id \\ nil)
  def check(true, _code, _path, _message, _id), do: :ok

  def check(false, code, path, message, id) do
    {:error, Result.diagnostic(code, path, message, id)}
  end

  @spec each(Enumerable.t(), (term() -> :ok | {:error, error})) :: :ok | {:error, error}
        when error: term()
  def each(values, fun) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case fun.(value) do
        :ok -> {:cont, :ok}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  @spec map([term()], (term() -> {:ok, value} | {:error, error})) ::
          {:ok, [value]} | {:error, error}
        when value: term(), error: term()
  def map([], _fun), do: {:ok, []}

  def map([value | rest], fun) do
    with {:ok, item} <- fun.(value), {:ok, items} <- map(rest, fun) do
      {:ok, [item | items]}
    end
  end
end
