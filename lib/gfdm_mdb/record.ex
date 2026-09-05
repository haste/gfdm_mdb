defmodule GfdmMdb.Record do
  @moduledoc "Canonical record patches and changes, including named difficulty families."

  @doc "Replaces supplied fields and complete difficulty families."
  @spec merge(map(), map()) :: map()
  def merge(record, patch) do
    Map.merge(record, patch, fn
      "difficulty", before, after_value when is_map(before) and is_map(after_value) ->
        Map.merge(before, after_value)

      _field, _before, after_value ->
        after_value
    end)
  end

  @doc "Maps changed canonical paths to before/after values. Arrays are compared in full."
  @spec changes(map(), map()) :: %{String.t() => %{before: term(), after: term()}}
  def changes(before, after_value), do: changes(before, after_value, "")

  defp changes(before, after_value, prefix) do
    for key <- Enum.uniq(Map.keys(before) ++ Map.keys(after_value)),
        field <- change(before[key], after_value[key], prefix <> key),
        into: %{},
        do: field
  end

  defp change(value, value, _path), do: %{}

  defp change(before, after_value, path) when is_map(before) and is_map(after_value),
    do: changes(before, after_value, path <> ".")

  defp change(before, after_value, path),
    do: %{path => %{before: before, after: after_value}}
end
