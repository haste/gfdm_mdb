defmodule GfdmMdb do
  @moduledoc "Database transformations and preparation of validated native or JSON output."

  alias GfdmMdb.Codec.{Binary, Cipher, Json, Xml}
  alias GfdmMdb.{Conversion, Database, Reindexer, Result, Schema, Validation}

  @type encoding :: :binary | :xml | :json
  @type result(value) :: {:ok, value} | {:error, Result.diagnostic()}
  @type imported :: {map(), Database.record_data()}

  @doc "Applies an operation to a valid database and prepares its output and report."
  @spec transform(Database.t(), String.t(), keyword()) :: Result.t()
  def transform(database, command, opts \\ []) do
    opts = Keyword.merge([kind: :songs, patch: %{}, keys: %{}], opts)
    prepare(database, operation(database, command, opts), opts)
  end

  @spec decode(binary(), keyword()) :: result(Database.t())
  def decode(bytes, opts \\ []) when is_binary(bytes) do
    result =
      case Keyword.get(opts, :encoding, detect_encoding(bytes)) do
        :binary ->
          Binary.decode(bytes)

        :xml ->
          Xml.decode(bytes, opts)

        :json ->
          Json.decode(bytes)

        _other ->
          {:error, Result.diagnostic(:encoding, "encoding", "Expected binary, xml, or json")}
      end

    with {:ok, decoded} <- result do
      decode_database(decoded, opts)
    end
  end

  @spec encode(Database.t(), keyword()) :: result(binary())
  def encode(database, opts \\ []) do
    database = output_database(database, opts)
    database = %{database | encrypted: Keyword.get(opts, :encrypted, database.encrypted)}

    with :ok <- Validation.validate(database, Keyword.get(opts, :encoding, :native)) do
      encode_valid(database, opts)
    end
  end

  @doc "Validates a candidate, computes its changes, and encodes it for preview or installation."
  @spec prepare(Database.t(), Result.t(), keyword()) :: Result.t()
  def prepare(before, result, opts \\ []) do
    result = output_result(result, opts)
    verification = Validation.verify(result.database, opts)

    result = %{
      result
      | errors: if(result.errors == [], do: verification.errors, else: result.errors),
        warnings: verification.warnings,
        changes: if(verification.valid, do: Database.changes(before, result.database), else: []),
        bytes: nil
    }

    if result.errors == [], do: encode_result(result, opts), else: result
  end

  @spec detect_encoding(binary()) :: encoding()
  def detect_encoding(<<"GF/DMmdb", _rest::binary>>), do: :binary

  def detect_encoding(bytes) when byte_size(bytes) >= 8 do
    # MDBE reversal puts the magic at the tail, so a prefix can resemble XML.
    tail = binary_part(bytes, byte_size(bytes) - 8, 8)
    if Cipher.decrypt(tail) == "GF/DMmdb", do: :binary, else: text_encoding(bytes)
  end

  def detect_encoding(bytes), do: text_encoding(bytes)

  ###
  ### Helpers
  ###

  defp output_result(%Result{database: %Database{} = database} = result, opts) do
    %{result | database: output_database(database, opts)}
  end

  defp output_result(result, _opts), do: result

  defp output_database(database, opts) do
    if opts[:encoding] == :json, do: database, else: Schema.Json.native_values(database)
  end

  defp decode_database(%Database{} = database, opts) do
    database = %{database | identity: Keyword.get(opts, :identity, database.identity)}

    with :ok <- Validation.validate(database, :json) do
      {:ok, database}
    end
  end

  defp decode_database({attributes, header}, opts) do
    attributes =
      Map.put(attributes, :identity, Keyword.get(opts, :identity, attributes[:identity]))

    Validation.decode(attributes, header)
  end

  defp operation(database, "convert", opts) do
    case opts[:target] do
      nil -> %Result{database: database}
      {format, version} -> Conversion.convert(database, format, version, opts)
    end
  end

  defp operation(database, "add", opts) do
    Database.add(database, opts[:record], opts[:kind])
  end

  defp operation(database, "edit", opts) do
    Database.edit(database, opts[:id], opts[:patch], opts[:kind])
  end

  defp operation(database, "clone", opts) do
    Database.clone(database, opts[:id], opts[:new_id], opts[:patch], opts[:kind])
  end

  defp operation(database, "remove", opts) do
    Database.remove(database, opts[:id], opts[:kind])
  end

  defp operation(database, "reindex", opts) do
    Reindexer.reindex(database, opts[:keys], opts)
  end

  defp encode_result(result, opts) do
    database = %{
      result.database
      | encrypted: Keyword.get(opts, :encrypted, result.database.encrypted)
    }

    with :ok <- Validation.encryption(database),
         {:ok, bytes} <- encode_valid(database, opts) do
      %{result | database: database, bytes: bytes}
    else
      {:error, error} -> Result.error(error, result)
    end
  end

  defp encode_valid(database, opts) do
    case Keyword.get(opts, :encoding, Schema.native_encoding(database.format)) do
      :binary ->
        Binary.encode(database)

      :xml ->
        Xml.encode(database)

      :json ->
        Json.encode(database)

      _other ->
        {:error, Result.diagnostic(:encoding, "encoding", "Expected binary, xml, or json")}
    end
  end

  defp text_encoding(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: text_encoding(rest)

  defp text_encoding(bytes) do
    case Regex.run(~r/\A[\x20\x09\x0a\x0d]*([<{])/, bytes) do
      [_, "<"] -> :xml
      [_, "{"] -> :json
      _other -> :binary
    end
  end
end
