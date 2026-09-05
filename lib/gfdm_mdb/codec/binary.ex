defmodule GfdmMdb.Codec.Binary do
  @moduledoc "Codec for packed MDB records and MDBE storage."

  alias GfdmMdb.Codec.Cipher
  alias GfdmMdb.{Database, Result, Schema, Validation}
  alias GfdmMdb.Schema.Field

  @doc "Decodes attributes and a separate wire header. GfdmMdb.decode/2 builds the database."
  @spec decode(binary()) :: GfdmMdb.result(GfdmMdb.imported())
  def decode(bytes) do
    case decode_plain(bytes, false) do
      {:ok, _imported} = result -> resolve_plain(bytes, result)
      {:error, _error} = error -> decode_encrypted(bytes, error)
    end
  end

  @doc "Encodes a valid database. `GfdmMdb.encode/2` validates first."
  @spec encode(Database.t()) :: GfdmMdb.result(binary())
  def encode(database) do
    with :ok <- Schema.validate(database.format) do
      song_fields = Schema.song_fields(database.format)
      course_fields = Schema.course_fields()

      plain =
        IO.iodata_to_binary([
          encode_record(Database.header(database), Schema.header_fields(database.format)),
          Enum.map(database.songs, &encode_record(&1, song_fields)),
          Enum.map(database.courses, &encode_record(&1, course_fields))
        ])

      {:ok, if(database.encrypted, do: Cipher.encrypt(plain), else: plain)}
    end
  end

  ###
  ### Helpers
  ###

  defp resolve_plain(bytes, {:ok, {attributes, header}} = result) do
    tail = binary_part(bytes, byte_size(bytes) - 8, 8)

    # Only ambiguous signatures need full validation before choosing plaintext.
    if Cipher.decrypt(tail) == "GF/DMmdb" do
      case Validation.decode(attributes, header) do
        {:ok, _database} -> result
        {:error, _error} = error -> decode_encrypted(bytes, error)
      end
    else
      result
    end
  end

  defp decode_plain(<<"GF/DMmdb", _rest::binary>> = plain, encrypted) do
    header_fields = Schema.header_fields(100)
    header_size = Schema.width(header_fields)

    with :ok <-
           Validation.check(
             byte_size(plain) >= header_size,
             :truncated,
             "native.header",
             "Expected #{header_size}-byte header"
           ),
         {header, rest} = decode_record(plain, header_fields),
         :ok <- Schema.validate(header["format"]),
         {:ok, songs, courses} <- tables(rest, header) do
      attributes = %{
        format: header["format"],
        songs: songs,
        courses: courses,
        encrypted: encrypted
      }

      {:ok, {attributes, header}}
    end
  end

  defp decode_plain(_bytes, _encrypted) do
    {:error,
     Result.diagnostic(
       :magic,
       "native.header.id",
       "Neither raw nor MDBE data has the GF/DMmdb signature"
     )}
  end

  # An MDBE prefix can resemble plaintext. Retry after an invalid raw layout.
  defp decode_encrypted(bytes, error) do
    case Cipher.decrypt(bytes) do
      <<"GF/DMmdb", _rest::binary>> = plain ->
        decode_plain(plain, true)

      _other ->
        error
    end
  end

  defp tables(bytes, header) do
    format = header["format"]
    header_size = Schema.width(Schema.header_fields(format))
    # Header size fields are legacy metadata, not physical table strides.
    expected =
      header["record_count"] * Schema.stride(format) +
        header["course_count"] * Schema.width(Schema.course_fields())

    with :ok <-
           Validation.check(
             byte_size(bytes) == expected,
             :size,
             "",
             "Table boundaries require #{expected + header_size} bytes. Got #{byte_size(bytes) + header_size}"
           ) do
      {songs, rest} = records(bytes, Schema.song_fields(format), header["record_count"])
      {courses, <<>>} = records(rest, Schema.course_fields(), header["course_count"])
      with {:ok, songs} <- Validation.map(songs, &decode_title/1), do: {:ok, songs, courses}
    end
  end

  defp decode_title(%{"music_id" => id, "title_ascii" => raw} = song) do
    case :binary.split(raw, <<0>>) do
      [text, padding] ->
        with :ok <-
               Validation.check(
                 String.valid?(text) and padding == :binary.copy(<<0>>, byte_size(padding)),
                 :title,
                 "songs.title_ascii",
                 "Expected UTF-8 text with zero padding",
                 id
               ) do
          {:ok, Map.put(song, "title_ascii", text)}
        end

      _other ->
        {:error,
         Result.diagnostic(:title, "songs.title_ascii", "Expected a NUL-terminated title", id)}
    end
  end

  defp records(bytes, fields, count) do
    Enum.map_reduce(List.duplicate(nil, count), bytes, fn _item, remaining ->
      decode_record(remaining, fields)
    end)
  end

  defp decode_record(bytes, fields) do
    Enum.reduce(fields, {%{}, bytes}, fn field, {record, rest} ->
      {value, rest} = decode_field(rest, field)
      {Map.put(record, field.name, value), rest}
    end)
  end

  defp decode_field(bytes, %{type: :object, fields: fields}), do: decode_record(bytes, fields)

  defp decode_field(bytes, %{type: type, count: count}) when type in [:hex, :title] do
    <<value::binary-size(^count), rest::binary>> = bytes
    {if(type == :hex, do: Base.encode16(value), else: value), rest}
  end

  defp decode_field(bytes, %{count: count} = field) when count > 1 do
    Enum.map_reduce(List.duplicate(nil, count), bytes, fn _item, rest ->
      decode_field(rest, %{field | count: 1})
    end)
  end

  defp decode_field(bytes, %{type: type}) do
    bits = Field.bits(type)

    if type in [:s8, :s16, :s32] do
      <<value::little-signed-size(^bits), rest::binary>> = bytes
      {value, rest}
    else
      <<value::little-unsigned-size(^bits), rest::binary>> = bytes
      {value, rest}
    end
  end

  defp encode_record(record, fields), do: Enum.map(fields, &encode_field(record, &1))

  defp encode_field(record, %{type: :object, name: name, fields: fields}),
    do: encode_record(record[name], fields)

  defp encode_field(record, %{type: :title, name: name, count: count}) do
    text = record[name]
    text <> :binary.copy(<<0>>, count - byte_size(text))
  end

  defp encode_field(record, %{type: :hex, name: name}) do
    Base.decode16!(record[name], case: :mixed)
  end

  defp encode_field(record, field) do
    values = if field.count == 1, do: [record[field.name]], else: record[field.name]
    bits = Field.bits(field.type)
    Enum.map(values, fn value -> <<value::little-size(bits)>> end)
  end
end
