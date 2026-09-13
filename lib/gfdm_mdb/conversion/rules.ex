defmodule GfdmMdb.Conversion.Rules do
  @moduledoc "Explicit conversion fallbacks and lossless array expansion."

  alias GfdmMdb.Schema.Field

  @spec apply(map(), [Field.t()], map()) :: {map(), [GfdmMdb.Conversion.issue()]}
  def apply(values, fields, overrides) do
    Enum.reduce(fields, {values, []}, fn field, {record, issues} ->
      case replacement(field, record, overrides) do
        {value, message} ->
          issue = %{
            kind: :filled,
            record_id: record["music_id"],
            path: "songs." <> field.name,
            message: message,
            value: value
          }

          {Map.put(record, field.name, value), issues ++ [issue]}

        nil ->
          {record, issues}
      end
    end)
  end

  defp replacement(field, record, overrides) do
    cond do
      Map.has_key?(overrides, field.name) -> nil
      record[field.name] == nil -> missing(field.name, record)
      true -> expand(field, record[field.name])
    end
  end

  defp missing("title_name", %{"title_ascii" => title}) when is_binary(title) do
    {title, "Copied title_ascii as the display-title fallback"}
  end

  defp missing("seq_id", record) do
    if record["is_classic_seq"] in [nil, 0],
      do: {record["music_id"], "Used music_id for the song's own sequences"}
  end

  defp missing("is_classic_seq", record) do
    if record["seq_id"] in [nil, record["music_id"]],
      do: {0, "Disabled classic sequence redirection"}
  end

  defp missing(_name, _record), do: nil

  defp expand(%{name: "disable_area", count: 3}, [first, second]) do
    {[first, second, 0], "Preserved existing regions and initialized the new region to zero"}
  end

  defp expand(_field, _value), do: nil
end
