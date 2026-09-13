defmodule GfdmMdb.Codec.Xml.Layout do
  @moduledoc "Maps canonical record fields to format-203 XML tags and flat difficulty arrays."

  alias GfdmMdb.{Schema, Validation}
  alias GfdmMdb.Schema.Field

  @names %{
    "guitar_offset" => "gf_ofst",
    "drum_offset" => "dm_ofst",
    "first_modern_ver" => "first_ver",
    "music_ids" => "music_id",
    "checksum" => "chksum",
    "header_size" => "header_sz",
    "record_size" => "record_sz",
    "course_size" => "course_sz",
    "record_count" => "record_nr",
    "course_count" => "course_nr"
  }

  @spec fields([Field.t()]) :: [map()]
  def fields(fields), do: Enum.flat_map(fields, &field/1)

  @spec signature([Field.t()]) :: [{String.t(), String.t(), String.t() | nil}]
  def signature(fields) do
    Enum.map(fields(fields), fn field ->
      {field.name, Atom.to_string(field.type), if(field.count != 1, do: to_string(field.count))}
    end)
  end

  @spec record([{map(), term()}]) :: map()
  def record(pairs) do
    Enum.reduce(pairs, %{}, fn {field, value}, record ->
      path = Enum.map(field.path, &Access.key(&1, %{}))
      put_in(record, path, value)
    end)
  end

  @spec decode(map(), term(), String.t(), integer() | nil) :: GfdmMdb.result(term())
  def decode(%{schema: %{type: :object}} = field, values, path, id) do
    with :ok <-
           Validation.check(
             is_list(values) and length(values) == field.count,
             :invalid_value,
             path,
             "Expected #{field.count} difficulty values",
             id
           ) do
      {record, []} = expand(values, field.schema.fields)
      {:ok, record}
    end
  end

  def decode(_field, value, _path, _id), do: {:ok, value}

  @spec value(map(), map()) :: term()
  def value(record, field) do
    value = get_in(record, field.path)
    if field.schema.type == :object, do: flatten(value, field.schema.fields), else: value
  end

  defp field(%{name: "difficulty", fields: families}) do
    Enum.map(families, fn family ->
      {name, type} =
        if family.name == "classic", do: {"classics_diff_list", :u8}, else: {"xg_diff_list", :u16}

      %{
        path: ["difficulty", family.name],
        name: name,
        type: type,
        count: div(Schema.width(family.fields), div(Field.bits(type), 8)),
        schema: family
      }
    end)
  end

  defp field(field),
    do: [
      %{
        path: [field.name],
        name: name(field.name),
        type: field.type,
        count: field.count,
        schema: field
      }
    ]

  defp name("modern_" <> suffix), do: "xg_" <> suffix
  defp name(name), do: Map.get(@names, name, name)

  defp flatten(record, fields) do
    Enum.flat_map(fields, fn
      %{type: :object} = field -> flatten(record[field.name], field.fields)
      field -> [record[field.name]]
    end)
  end

  defp expand(values, fields) do
    {pairs, rest} = Enum.map_reduce(fields, values, &expand_field/2)
    {Map.new(pairs), rest}
  end

  defp expand_field(%{type: :object} = field, values) do
    {record, rest} = expand(values, field.fields)
    {{field.name, record}, rest}
  end

  defp expand_field(field, [value | rest]), do: {{field.name, value}, rest}
end
