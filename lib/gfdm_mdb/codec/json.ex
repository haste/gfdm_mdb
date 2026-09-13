defmodule GfdmMdb.Codec.Json do
  @moduledoc "Codec for MDB JSON: shared records and separate native reconstruction metadata."

  alias GfdmMdb.{Database, Result, Schema, Validation}

  @keys ~w(json_version identity native songs courses)

  @doc "Decodes an envelope into a database candidate. GfdmMdb.decode/2 validates it."
  @spec decode(binary()) :: GfdmMdb.result(Database.t())
  def decode(bytes) do
    with {:ok, map} <- parse(bytes) do
      database(map)
    end
  end

  @doc "Encodes a valid database. `GfdmMdb.encode/2` validates first."
  @spec encode(Database.t()) :: GfdmMdb.result(binary())
  def encode(database) do
    {:ok, pretty(envelope(database))}
  end

  @spec pretty(term()) :: binary()
  def pretty(value) do
    formatter = fn
      nil, _encoder, _state -> "null"
      :null, _encoder, _state -> ~s("null")
      value, encoder, state -> :json.format_value(value, encoder, state)
    end

    value
    |> :json.format(formatter, %{indent: 2, max: 88})
    |> IO.iodata_to_binary()
  end

  @spec parse(binary()) :: GfdmMdb.result(term())
  def parse(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: parse(rest)

  def parse(bytes) do
    decoders = [
      object_finish: fn fields, acc ->
        map = Map.new(fields)
        if map_size(map) != length(fields), do: throw(:duplicate_json_key)
        {map, acc}
      end
    ]

    case JSON.decode(bytes, nil, decoders) do
      {value, nil, rest} ->
        with :ok <- Validation.check(String.trim(rest) == "", :json, "", "Trailing JSON data") do
          {:ok, value}
        end

      {:error, reason} ->
        {:error, Result.diagnostic(:json, "", "Malformed JSON: #{inspect(reason)}")}
    end
  catch
    :duplicate_json_key ->
      {:error, Result.diagnostic(:duplicate_key, "", "Duplicate JSON object key")}
  end

  @spec envelope(Database.t()) :: %{String.t() => term()}
  def envelope(database) do
    fields = Schema.Json.song_fields()

    native = %{
      "format" => database.format,
      "encrypted" => database.encrypted,
      "header" => database.header
    }

    native =
      if database.format == 203,
        do: Map.put(native, "schema_version", database.schema_version),
        else: native

    %{
      "json_version" => 1,
      "identity" => database.identity,
      "native" => native,
      "songs" => Enum.map(database.songs, &Schema.Json.expand(&1, fields)),
      "courses" => database.courses
    }
  end

  ###
  ### Helpers
  ###

  defp database(map) when is_map(map) do
    with :ok <-
           Validation.check(
             Map.keys(map) -- @keys == [],
             :unknown_field,
             "",
             "Unknown JSON envelope keys"
           ),
         :ok <-
           Validation.check(
             map["json_version"] === 1,
             :json_version,
             "json_version",
             "Expected JSON version 1"
           ),
         {:ok, database} <- native(map["native"]) do
      {:ok,
       %{
         database
         | identity: map["identity"],
           songs: map["songs"],
           courses: map["courses"]
       }}
    end
  end

  defp database(_value) do
    {:error, Result.diagnostic(:json, "", "Expected a JSON envelope object")}
  end

  defp native(native) do
    with :ok <-
           Validation.check(
             is_map(native),
             :metadata,
             "native",
             "Expected native reconstruction metadata"
           ),
         :ok <-
           Validation.check(
             Map.keys(native) -- ~w(format schema_version encrypted header) == [],
             :metadata,
             "native",
             "Unknown native metadata"
           ),
         :ok <-
           Validation.check(
             native["format"] == 203 or not Map.has_key?(native, "schema_version"),
             :schema,
             "native.schema_version",
             "Omit schema_version for binary formats"
           ) do
      {:ok,
       %Database{
         format: native["format"],
         schema_version: native["schema_version"],
         header: native["header"],
         encrypted: native["encrypted"]
       }}
    end
  end
end
