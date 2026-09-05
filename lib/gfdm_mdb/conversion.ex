defmodule GfdmMdb.Conversion do
  @moduledoc "Schema conversion candidates with explicit replacements and loss approval."

  alias GfdmMdb.{Database, Record, Result, Schema, Validation}
  alias GfdmMdb.Schema.Field

  @type schema :: %{format: Schema.format(), schema_version: Schema.version()}
  @type issue :: %{
          kind: :missing | :removed | :incompatible,
          record_id: integer() | nil,
          path: String.t(),
          message: String.t(),
          value: term()
        }
  @type report :: %{
          source: schema(),
          target: schema(),
          issues: [issue()]
        }

  @spec convert(Database.t(), Schema.format(), Schema.version(), keyword()) ::
          Result.t()
  def convert(database, format, version \\ nil, opts \\ []) do
    with :ok <- Schema.validate(format, version),
         defaults = Keyword.get(opts, :defaults, %{}),
         overrides = Keyword.get(opts, :overrides, %{}),
         fields = Schema.song_fields(format, version),
         :ok <- validate_options(defaults, overrides, fields, database) do
      target = Database.new(format, version)

      {songs, issues} =
        database.songs
        |> Enum.map(fn song ->
          values =
            defaults
            |> Record.merge(song)
            |> Record.merge(Map.get(overrides, Integer.to_string(song["music_id"]), %{}))

          map_record(values, fields, song["music_id"], "songs.")
        end)
        |> Enum.unzip()

      header = if format == database.format, do: database.header, else: target.header

      candidate = %{
        target
        | identity: database.identity,
          songs: songs,
          courses: database.courses,
          header: header,
          encrypted: format != 203 and database.encrypted
      }

      issues = List.flatten(issues) ++ header_loss(database, target)
      ready = Enum.all?(issues, &(&1.kind == :removed and Keyword.get(opts, :allow_loss, false)))

      report = %{
        source: %{format: database.format, schema_version: database.schema_version},
        target: %{format: format, schema_version: version},
        issues: issues
      }

      if ready do
        Result.new({:ok, candidate}, %{conversion: report})
      else
        Result.error(
          Result.diagnostic(
            :conversion,
            "",
            "Conversion requires explicit values or loss permission"
          ),
          %Result{database: candidate, reports: %{conversion: report}}
        )
      end
    else
      {:error, error} -> Result.error(error)
    end
  end

  ###
  ### Helpers
  ###

  defp validate_options(defaults, overrides, fields, database) do
    with :ok <-
           Validation.check(
             is_map(defaults) and is_map(overrides),
             :conversion,
             "defaults",
             "Defaults and overrides must be JSON objects"
           ),
         :ok <- check_keys(defaults, fields, "defaults") do
      ids = MapSet.new(database.songs, &Integer.to_string(&1["music_id"]))
      Validation.each(overrides, &validate_override(&1, ids, fields))
    end
  end

  defp validate_override({id, values}, ids, fields) do
    with :ok <-
           Validation.check(
             MapSet.member?(ids, id),
             :conversion,
             "overrides.#{id}",
             "Unknown song ID"
           ),
         :ok <-
           Validation.check(is_map(values), :conversion, "overrides.#{id}", "Expected object") do
      check_keys(values, fields, "overrides.#{id}")
    end
  end

  defp check_keys(map, fields, path) do
    names = Enum.map(fields, & &1.name)

    with :ok <-
           Validation.check(
             Map.keys(map) -- names == [],
             :unknown_field,
             path,
             "Replacement contains fields absent from the target schema"
           ) do
      fields
      |> Enum.filter(&(&1.type == :object and Map.has_key?(map, &1.name)))
      |> Validation.each(
        &Validation.validate_patch(map[&1.name], &1.fields, path <> "." <> &1.name)
      )
    end
  end

  defp map_record(values, fields, id, prefix) do
    names = Enum.map(fields, & &1.name)

    removed =
      for name <- Map.keys(values) -- names do
        issue(:removed, id, prefix <> name, "Field is absent from target", values[name])
      end

    Enum.reduce(fields, {Map.take(values, names), removed}, fn field, {record, issues} ->
      {value, field_issues} =
        map_field(Map.get(values, field.name, :missing), field, id, prefix <> field.name)

      record = if value == :missing, do: record, else: Map.put(record, field.name, value)
      {record, issues ++ field_issues}
    end)
  end

  defp map_field(value, %{name: "difficulty", fields: fields}, id, path) when is_map(value),
    do: map_record(value, fields, id, path <> ".")

  defp map_field(:missing, _field, id, path),
    do: {:missing, [issue(:missing, id, path, "Supply a default or record override", nil)]}

  defp map_field(value, field, id, path) do
    case Field.validate(field, value, path, id) do
      :ok ->
        {value, []}

      {:error, error} ->
        {value,
         [
           issue(
             :incompatible,
             id,
             error.path,
             "Supply a record override. " <> error.message,
             value
           )
         ]}
    end
  end

  defp header_loss(database, target) when database.format == target.format do
    []
  end

  defp header_loss(database, _target) do
    expected = Schema.default_header(database.format)

    for {key, value} <- database.header,
        value != expected[key] do
      %{
        kind: :removed,
        record_id: nil,
        path: "native.header." <> key,
        message: "Nonstandard source header value is not retained across formats",
        value: value
      }
    end
  end

  defp issue(kind, id, field, message, value) do
    %{kind: kind, record_id: id, path: field, message: message, value: value}
  end
end
