defmodule GfdmMdb.Schema.Json do
  @moduledoc "The union of native song schemas, with nullable version-specific fields."

  alias GfdmMdb.{Database, Schema}
  alias GfdmMdb.Schema.Field

  @spec song_fields() :: [Field.t()]
  def song_fields do
    schemas = [{100, nil}, {101, nil}, {102, nil}, {202, nil}] ++ Enum.map(1..6, &{203, &1})

    schemas
    |> Enum.map(fn {format, version} -> Schema.song_fields(format, version) end)
    |> union()
  end

  @doc "Includes every known field, using null for values absent from the source."
  @spec expand(Database.record_data(), [Field.t()]) :: Database.record_data()
  def expand(record, fields) do
    Enum.reduce(fields, record, fn field, expanded ->
      value = Map.get(record, field.name)

      value =
        if field.type == :object and is_map(value),
          do: expand(value, field.fields),
          else: value

      Map.put(expanded, field.name, value)
    end)
  end

  @doc "Treats nullable fields as missing when preparing a native conversion or output."
  @spec native_values(Database.t()) :: Database.t()
  def native_values(database) do
    fields = song_fields()

    songs =
      if is_list(database.songs),
        do: Enum.map(database.songs, &native_record(&1, fields)),
        else: database.songs

    %{database | songs: songs}
  end

  defp union(schemas) do
    schemas
    |> List.flatten()
    |> Enum.uniq_by(& &1.name)
    |> Enum.map(fn field ->
      variants = for fields <- schemas, variant <- fields, variant.name == field.name, do: variant
      merged = merge(Enum.uniq(variants))
      %{merged | optional: length(variants) < length(schemas)}
    end)
  end

  defp merge([%{type: :object} = field | _rest] = variants) do
    %{field | fields: union(Enum.map(variants, & &1.fields))}
  end

  defp merge([field]), do: field

  defp merge([field | _rest] = variants) do
    %{field | type: :union, count: 1, fields: variants}
  end

  defp native_record(record, fields) when is_map(record) do
    Enum.reduce(fields, record, fn field, native ->
      case Map.fetch(record, field.name) do
        {:ok, nil} when field.optional ->
          Map.delete(native, field.name)

        {:ok, value} when field.type == :object ->
          Map.put(native, field.name, native_record(value, field.fields))

        _other ->
          native
      end
    end)
  end

  defp native_record(record, _fields), do: record
end
