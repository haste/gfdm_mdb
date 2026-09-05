defmodule GfdmMdb.Cli.RecordPatch do
  @moduledoc "Applies JSON patches followed by ordered assignments to existing record paths."

  alias GfdmMdb.Cli.Arguments
  alias GfdmMdb.Codec.Json
  alias GfdmMdb.{Database, Record, Schema, Validation}

  @spec build(Database.t(), map()) :: GfdmMdb.result(Database.record_data())
  def build(database, opts) do
    patch = Map.get(opts, :patch, %{})
    fields = Schema.record_fields(database, opts[:kind])

    with :ok <- Validation.check(is_map(patch), :usage, "patch", "Patch must be a JSON object"),
         {:ok, record} <- Database.fetch(database, opts[:id], opts[:kind]),
         {:ok, {updated, touched}} <-
           assignments(
             Map.get(opts, :set, []),
             record,
             Record.merge(record, patch),
             Map.keys(patch)
           ),
         patch = Map.take(updated, touched),
         :ok <- Validation.validate_patch(patch, fields, Atom.to_string(opts[:kind]), opts[:id]) do
      {:ok, patch}
    end
  end

  ###
  ### Helpers
  ###

  defp assignments(assignments, original, updated, touched) do
    Enum.reduce_while(assignments, {:ok, {updated, touched}}, fn assignment, {:ok, state} ->
      case assign(assignment, original, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        error -> {:halt, error}
      end
    end)
  end

  defp assign(assignment, original, {record, touched}) do
    case String.split(assignment, "=", parts: 2) do
      [name, text] ->
        path = String.split(name, ".")

        with {:ok, previous} <- lookup(original, path, name),
             {:ok, value} <- value(previous, text),
             {:ok, updated} <- put(record, path, value, name) do
          {:ok, {updated, [hd(path) | touched]}}
        end

      _other ->
        Arguments.usage("--set requires field=value")
    end
  end

  defp lookup(value, [], _name), do: {:ok, value}

  defp lookup(value, [key | rest], name) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, value} -> lookup(value, rest, name)
      :error -> Arguments.usage("Unknown field #{name}")
    end
  end

  defp lookup(_value, _path, name), do: Arguments.usage("Unknown field #{name}")

  defp value(previous, text) when is_binary(previous), do: {:ok, text}
  defp value(_previous, text), do: Json.parse(text)

  defp put(record, [key], value, _name) when is_map(record),
    do: {:ok, Map.put(record, key, value)}

  defp put(record, [key | rest], value, name) when is_map(record) do
    with {:ok, updated} <- put(Map.get(record, key, %{}), rest, value, name) do
      {:ok, Map.put(record, key, updated)}
    end
  end

  defp put(_record, _path, _value, name),
    do: Arguments.usage("Cannot assign #{name}: a parent value is not an object")
end
