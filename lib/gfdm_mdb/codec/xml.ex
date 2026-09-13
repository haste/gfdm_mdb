defmodule GfdmMdb.Codec.Xml do
  @moduledoc "Codec for typed MDB XML with ordered schema detection."

  alias GfdmMdb.Codec.Xml.Layout
  alias GfdmMdb.{Database, Result, Schema, Validation}

  @doc "Decodes attributes and a separate wire header. GfdmMdb.decode/2 builds the database."
  @spec decode(binary(), keyword()) :: GfdmMdb.result(GfdmMdb.imported())
  def decode(bytes, opts \\ []) do
    with {:ok, root} <- parse(bytes),
         :ok <- container(root, "mdb"),
         {:ok, header, nodes} <- header(root.children),
         {songs, courses} = Enum.split_while(nodes, &(&1.name == "mdb_data")),
         :ok <- Validation.each(songs, &container(&1, "mdb_data")),
         :ok <- Validation.each(courses, &container(&1, "mdb_course")),
         {:ok, version} <- version(songs, Keyword.get(opts, :schema_version)),
         song_fields = Schema.song_fields(203, version),
         course_fields = Schema.course_fields(),
         {:ok, songs} <- Validation.map(songs, &typed(&1.children, song_fields, "songs")),
         {:ok, courses} <- Validation.map(courses, &typed(&1.children, course_fields, "courses")) do
      attributes = %{
        format: 203,
        schema_version: version,
        songs: songs,
        courses: courses
      }

      {:ok, {attributes, header}}
    end
  end

  @doc "Encodes a valid database. `GfdmMdb.encode/2` validates first."
  @spec encode(Database.t()) :: GfdmMdb.result(binary())
  def encode(database) do
    with :ok <-
           Validation.check(
             database.format == 203,
             :schema,
             "native.format",
             "XML requires format 203. Convert explicitly first"
           ),
         song_fields = Schema.song_fields(203, database.schema_version),
         :ok <- xml_strings(database.songs, song_fields) do
      course_fields = Schema.course_fields()

      data = xml_container("data", emit(Database.header(database), Schema.header_fields(203)))
      header = xml_container("header", [data])
      songs = Enum.map(database.songs, &xml_container("mdb_data", emit(&1, song_fields)))
      courses = Enum.map(database.courses, &xml_container("mdb_course", emit(&1, course_fields)))

      xml =
        "mdb"
        |> xml_container([header] ++ songs ++ courses)
        |> Saxy.encode!(version: "1.0", encoding: "UTF-8")
        |> String.replace("\r", "&#13;")

      {:ok, xml <> "\n"}
    end
  end

  ###
  ### Helpers
  ###

  defp parse(bytes) do
    case Saxy.SimpleForm.parse_string(bytes, expand_entity: {:erlang, :throw, []}) do
      {:ok, root} -> {:ok, xml_node(root)}
      {:error, error} -> {:error, Result.diagnostic(:xml, "", Exception.message(error))}
    end
  catch
    name when is_binary(name) ->
      {:error, Result.diagnostic(:xml, "", "Unsupported XML entity: &#{name};")}
  end

  defp xml_node({name, attrs, content}) do
    {children, text} = Enum.split_with(content, &is_tuple/1)

    %{
      name: name,
      attrs: attrs,
      children: Enum.map(children, &xml_node/1),
      text: IO.iodata_to_binary(text)
    }
  end

  defp header([%{name: "header", children: [data]} = header | nodes]) do
    with :ok <- container(header, "header"),
         :ok <- container(data, "data"),
         {:ok, values} <- typed(data.children, Schema.header_fields(203), "native.header") do
      {:ok, values, nodes}
    end
  end

  defp header(_nodes) do
    {:error, Result.diagnostic(:xml, "header", "Expected one header/data node first")}
  end

  defp version([], nil) do
    {:error,
     Result.diagnostic(
       :schema_hint,
       "native.schema_version",
       "Empty XML requires a schema_version hint (1-6)"
     )}
  end

  defp version([], hint) do
    with :ok <- Schema.validate(203, hint), do: {:ok, hint}
  end

  defp version([first | _songs], hint) do
    signature = signature(first.children)

    version =
      Enum.find(
        Schema.versions(),
        &(Layout.signature(Schema.song_fields(203, &1)) == signature)
      )

    with :ok <-
           Validation.check(
             version != nil,
             :schema,
             "songs",
             "Unknown ordered song field/type/count signature"
           ),
         :ok <-
           Validation.check(
             hint == nil or hint == version,
             :schema,
             "native.schema_version",
             "Schema hint disagrees with song signature"
           ) do
      {:ok, version}
    end
  end

  defp signature(nodes) do
    Enum.map(nodes, fn node ->
      attrs = Map.new(node.attrs)
      {node.name, attrs["__type"], attrs["__count"]}
    end)
  end

  defp typed(nodes, fields, path) do
    with :ok <-
           Validation.check(
             signature(nodes) == Layout.signature(fields),
             :schema,
             path,
             "Fields, order, types, or counts differ from the selected schema"
           ),
         id = record_id(nodes, path),
         {:ok, values} <-
           Validation.map(Enum.zip(nodes, Layout.fields(fields)), &leaf(&1, path, id)) do
      {:ok, Layout.record(values)}
    end
  end

  defp record_id(nodes, path) when path in ["songs", "courses"] do
    name = if path == "songs", do: "music_id", else: "course_id"
    node = Enum.find(nodes, &(&1.name == name))

    case Integer.parse(String.trim(node.text)) do
      {id, ""} -> id
      _other -> nil
    end
  end

  defp record_id(_nodes, _path), do: nil

  defp leaf({node, field}, path, id) do
    attrs = if field.count == 1, do: ["__type"], else: ["__count", "__type"]
    field_path = path <> "." <> Enum.join(field.path, ".")

    with :ok <-
           Validation.check(
             Enum.sort(Enum.map(node.attrs, &elem(&1, 0))) == attrs and node.children == [],
             :xml,
             field_path,
             "Invalid field hierarchy or annotations"
           ),
         {:ok, value} <- value(node.text, field, path),
         {:ok, value} <- Layout.decode(field, value, field_path, id) do
      {:ok, {field, value}}
    end
  end

  defp value(text, %{type: :str}, _path), do: {:ok, text}

  defp value(text, %{count: count} = field, path) when count > 1 do
    Validation.map(String.split(text), &value(&1, %{field | count: 1}, path))
  end

  defp value(text, field, path) do
    case Integer.parse(String.trim(text)) do
      {integer, ""} ->
        {:ok, integer}

      _other ->
        {:error,
         Result.diagnostic(
           :number,
           path <> "." <> Enum.join(field.path, "."),
           "Expected a decimal integer"
         )}
    end
  end

  defp container(node, name) do
    Validation.check(
      node.name == name and node.attrs == [] and String.trim(node.text) == "",
      :xml,
      name,
      "Invalid XML hierarchy or container annotations"
    )
  end

  defp xml_container(name, children) do
    content = ["\n" | Enum.flat_map(children, &[&1, "\n"])]
    Saxy.XML.element(name, [], content)
  end

  defp emit(record, fields) do
    Enum.map(Layout.fields(fields), fn field ->
      value = Layout.value(record, field)
      count = if field.count == 1, do: [], else: [__count: field.count]

      text =
        if is_list(value) do
          Enum.join(value, " ")
        else
          to_string(value)
        end

      Saxy.XML.element(field.name, [__type: field.type] ++ count, Saxy.XML.characters(text))
    end)
  end

  defp xml_strings(songs, fields) do
    fields = Enum.filter(fields, &(&1.type == :str))

    strings =
      for song <- songs, field <- fields do
        {song["music_id"], field.name, song[field.name]}
      end

    Validation.each(strings, fn {id, field, text} ->
      valid =
        Enum.all?(String.to_charlist(text), fn char ->
          char in [9, 10, 13] or (char >= 32 and char not in [0xFFFE, 0xFFFF])
        end)

      Validation.check(
        valid,
        :xml_character,
        "songs." <> field,
        "String contains a character forbidden in XML 1.0",
        id
      )
    end)
  end
end
