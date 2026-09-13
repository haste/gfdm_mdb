defmodule GfdmMdb.Database do
  @moduledoc "Canonical records and native reconstruction metadata. GfdmMdb.transform/3 prepares edits."

  alias GfdmMdb.{Record, Result, Schema, Validation}

  @type kind :: :songs | :courses
  @type record_data :: %{optional(String.t()) => GfdmMdb.Schema.Field.value()}
  @type t :: %__MODULE__{
          format: Schema.format(),
          schema_version: Schema.version(),
          identity: String.t() | nil,
          header: record_data(),
          songs: [record_data()],
          courses: [record_data()],
          encrypted: boolean()
        }

  @type change :: %{
          required(:kind) => kind(),
          required(:record_id) => integer(),
          required(:action) => :added | :removed | :updated,
          optional(:fields) => %{
            optional(String.t()) => %{before: term(), after: term()}
          }
        }

  defstruct [
    :format,
    :schema_version,
    :identity,
    header: %{},
    songs: [],
    courses: [],
    encrypted: false
  ]

  @spec new(Schema.format(), Schema.version()) :: t()
  def new(format, version \\ nil) do
    %__MODULE__{
      format: format,
      schema_version: version,
      header:
        Map.take(
          Schema.default_header(format),
          Enum.map(Schema.metadata_fields(format), & &1.name)
        )
    }
  end

  @spec fetch(t(), integer(), kind()) :: GfdmMdb.result(record_data())
  def fetch(database, id, kind \\ :songs) do
    id_field = Schema.id_field(kind)

    case Enum.find(Map.fetch!(database, kind), &(&1[id_field] == id)) do
      nil ->
        {:error,
         Result.diagnostic(:not_found, Atom.to_string(kind), "Record #{id} not found", id)}

      record ->
        {:ok, record}
    end
  end

  @spec add(t(), record_data(), kind()) :: Result.t()
  def add(database, record, kind \\ :songs) do
    Result.new(insert(database, record, kind))
  end

  defp insert(database, record, kind) do
    id = if(is_map(record), do: record[Schema.id_field(kind)])

    with :ok <-
           Validation.validate_record(
             record,
             Schema.record_fields(database, kind, :json),
             Atom.to_string(kind),
             id
           ) do
      records = insert_record(Map.fetch!(database, kind), record, kind)
      put_records(database, kind, records)
    end
  end

  @spec remove(t(), integer(), kind()) :: Result.t()
  def remove(database, id, kind \\ :songs) do
    result =
      with {:ok, _record} <- fetch(database, id, kind) do
        records = Enum.reject(Map.fetch!(database, kind), &(&1[Schema.id_field(kind)] == id))
        put_records(database, kind, records)
      end

    Result.new(result)
  end

  @spec edit(t(), integer(), record_data(), kind()) :: Result.t()
  def edit(database, id, patch, kind \\ :songs) do
    result =
      with {:ok, record} <- fetch(database, id, kind) do
        updated = Record.merge(record, patch)
        id_field = Schema.id_field(kind)

        records =
          Enum.map(Map.fetch!(database, kind), &if(&1[id_field] == id, do: updated, else: &1))

        put_records(database, kind, records)
      end

    Result.new(result)
  end

  @spec clone(t(), integer(), integer(), record_data(), kind()) :: Result.t()
  def clone(database, id, new_id, patch \\ %{}, kind \\ :songs) do
    result =
      with {:ok, record} <- fetch(database, id, kind),
           :ok <-
             Validation.check(
               Map.get(patch, Schema.id_field(kind), new_id) === new_id,
               :patch,
               Atom.to_string(kind) <> "." <> Schema.id_field(kind),
               "Patch ID conflicts with the requested new ID",
               id
             ) do
        insert(
          database,
          record |> Record.merge(patch) |> Map.put(Schema.id_field(kind), new_id),
          kind
        )
      end

    Result.new(result)
  end

  @doc "Builds a wire header from preserved metadata and current records."
  @spec header(t()) :: record_data()
  def header(database) do
    database.format
    |> Schema.default_header()
    |> Map.merge(database.header)
    |> Map.merge(%{
      "record_count" => length(database.songs),
      "course_count" => length(database.courses)
    })
  end

  @spec changes(t(), t()) :: [change()]
  def changes(before, updated) do
    Enum.flat_map([:songs, :courses], fn kind ->
      id = Schema.id_field(kind)
      previous_records = Map.fetch!(before, kind)
      current_records = Map.fetch!(updated, kind)
      previous = Map.new(previous_records, &{&1[id], &1})
      current = Map.new(current_records, &{&1[id], &1})

      removed =
        for record <- previous_records,
            not Map.has_key?(current, record[id]),
            do: %{kind: kind, record_id: record[id], action: :removed}

      removed ++
        Enum.flat_map(current_records, fn record ->
          change(kind, record[id], previous[record[id]], record)
        end)
    end)
  end

  ###
  ### Helpers
  ###

  defp insert_record(records, record, kind) do
    id = Schema.id_field(kind)
    ids = Enum.map(records, & &1[id])
    combined = List.insert_at(records, -1, record)
    if ids == Enum.sort(ids), do: Enum.sort_by(combined, & &1[id]), else: combined
  end

  defp put_records(database, kind, records) do
    {:ok, Map.put(database, kind, records)}
  end

  defp change(kind, id, nil, _record), do: [%{kind: kind, record_id: id, action: :added}]
  defp change(_kind, _id, previous, record) when previous == record, do: []

  defp change(kind, id, previous, record) do
    [%{kind: kind, record_id: id, action: :updated, fields: Record.changes(previous, record)}]
  end
end
