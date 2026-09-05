defmodule GfdmMdbTest do
  use ExUnit.Case, async: true
  alias GfdmMdb.Codec.Cipher
  alias GfdmMdb.{Database, Fixture, Schema, Validation}

  for {format, stride} <- [{100, 188}, {101, 192}, {102, 192}, {202, 232}] do
    test "format #{format} plaintext and MDBE files preserve records and use the expected size" do
      database = Fixture.database(unquote(format))
      song = hd(database.songs) |> Map.put("pad_diff", 1) |> Map.put("seq_flag", 255)

      database = %{
        database
        | header: Map.put(database.header, "reserved", "AB" <> String.duplicate("00", 37)),
          songs: [song]
      }

      for encrypted <- [false, true] do
        assert {:ok, bytes} = GfdmMdb.encode(database, encrypted: encrypted)
        assert byte_size(bytes) == 64 + unquote(stride) + 40
        assert {:ok, decoded} = GfdmMdb.decode(bytes)
        assert decoded.encrypted == encrypted
        assert decoded.songs == database.songs
        assert decoded.header == database.header
        assert decoded.courses == database.courses
        assert {:ok, ^bytes} = GfdmMdb.encode(decoded)
      end
    end
  end

  test "encoding rejects invalid records and encryption for native and JSON output" do
    for {format, version} <- [{102, nil}, {203, 6}],
        encoding <- [Schema.native_encoding(format), :json] do
      database = Fixture.database(format, version)
      invalid = %{database | songs: [Map.put(hd(database.songs), "bpm", 65_536)]}

      assert {:error, %{code: :invalid_value, path: "songs.bpm", record_id: 1120}} =
               GfdmMdb.encode(invalid, encoding: encoding)

      assert {:error, %{code: :metadata, path: "native.encrypted"}} =
               GfdmMdb.encode(database, encoding: encoding, encrypted: nil)
    end

    assert {:error, %{code: :metadata, path: "native.encrypted"}} =
             GfdmMdb.encode(Fixture.database(203, 6), encrypted: true)
  end

  test "empty databases are valid but missing, truncated and trailing bytes are rejected" do
    database = Database.new(102)
    assert {:ok, bytes} = GfdmMdb.encode(database)
    assert byte_size(bytes) == 64
    assert {:ok, ^database} = GfdmMdb.decode(bytes)

    for invalid <- [<<>>, binary_part(bytes, 0, 63), bytes <> <<0>>] do
      assert {:error, _error} = GfdmMdb.decode(invalid)
    end

    assert {:ok, populated} = GfdmMdb.encode(Fixture.database())
    assert {:error, _error} = GfdmMdb.decode(binary_part(populated, 0, byte_size(populated) - 1))
  end

  test "header format and metadata are validated while non-stride metadata is retained" do
    database = Fixture.database()
    assert {:ok, bytes} = GfdmMdb.encode(database)
    <<prefix::binary-size(8), _format::binary-size(4), rest::binary>> = bytes
    assert {:error, %{code: :schema}} = GfdmMdb.decode(prefix <> <<999::little-32>> <> rest)

    <<counts::binary-size(4), _size::binary-size(2), rest::binary>> = rest

    assert {:error, _error} =
             GfdmMdb.decode(prefix <> <<102::little-32>> <> counts <> <<65::little-16>> <> rest)

    changed = %{
      database
      | header: Map.merge(database.header, %{"record_size" => 1, "course_size" => 1})
    }

    assert {:ok, changed_bytes} = GfdmMdb.encode(changed)
    assert {:ok, ^changed} = GfdmMdb.decode(changed_bytes)
    assert %{valid: true, warnings: warnings} = Validation.verify(changed)

    assert Enum.map(warnings, & &1.path) == [
             "native.header.record_size",
             "native.header.course_size"
           ]

    refute Validation.verify(changed, strict: true).valid
  end

  test "binary titles allow 15 UTF-8 bytes and reject invalid file values" do
    database = Fixture.database()

    for text <- ["日本語", "123456789012345", "日本語日本"] do
      assert %{database: edited, errors: []} =
               GfdmMdb.transform(database, "edit", id: 1120, patch: %{"title_ascii" => text})

      assert {:ok, bytes} = GfdmMdb.encode(edited)
      assert {:ok, ^edited} = GfdmMdb.decode(bytes)
    end

    assert {:ok, json} = GfdmMdb.encode(database, encoding: :json)
    envelope = JSON.decode!(json)

    for text <- ["1234567890123456", "日本語日本語", "a\0b", nil, 123] do
      invalid = Map.put(envelope, "songs", [Map.put(hd(envelope["songs"]), "title_ascii", text)])

      assert {:error, %{code: :title, record_id: 1120}} =
               invalid |> JSON.encode!() |> GfdmMdb.decode()
    end

    assert {:ok, bytes} = GfdmMdb.encode(database)
    <<prefix::binary-size(96), _title::binary-size(16), rest::binary>> = bytes

    assert {:error, %{code: :title}} =
             GfdmMdb.decode(prefix <> <<255, 0::120>> <> rest)
  end

  test "MDBE fallback includes shared header validation when both signatures match" do
    assert {:ok, plain} = GfdmMdb.encode(Fixture.database())

    <<header_prefix::binary-size(16), _header_size::binary-size(2), header_rest::binary-size(46),
      _tables::binary>> = plain

    <<_header::binary-size(64), stored_tables::binary>> = Cipher.encrypt(plain)
    stored = header_prefix <> <<65::little-16>> <> header_rest <> stored_tables

    title_offset =
      64 +
        (Schema.song_fields(102)
         |> Enum.take_while(&(&1.name != "title_ascii"))
         |> Schema.width())

    <<prefix::binary-size(^title_offset), _title::binary-size(16), rest::binary>> = stored
    stored = prefix <> :binary.copy(<<0>>, 16) <> rest

    # Both interpretations have valid table layouts; the raw header size is invalid.
    # Modified ciphertext touches only course data and song metric bytes in plaintext.
    assert {:ok, database} = stored |> Cipher.decrypt() |> GfdmMdb.decode()
    database = %{database | encrypted: true}
    assert {:ok, ^stored} = GfdmMdb.encode(database)
    assert {:ok, ^database} = GfdmMdb.decode(stored)
  end
end
