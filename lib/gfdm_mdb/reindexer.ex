defmodule GfdmMdb.Reindexer do
  @moduledoc "Builds reindex candidates with database sort ranks from caller-supplied keys."

  alias GfdmMdb.{Result, Schema, Validation}

  @type sort_key :: %{
          optional(String.t()) => String.t() | integer() | nil
        }
  @type keys :: %{optional(String.t()) => %{optional(String.t()) => sort_key()}}

  @spec reindex(GfdmMdb.Database.t(), keys(), keyword()) ::
          Result.t()
  def reindex(database, keys, opts \\ []) do
    result =
      with :ok <-
             Validation.check(
               is_map(keys),
               :sort_keys,
               "keys",
               "Expected a JSON object keyed by music ID"
             ),
           groups = groups(Keyword.get(opts, :select, :title)),
           ids = Enum.map(database.songs, &Integer.to_string(&1["music_id"])),
           :ok <-
             Validation.check(
               Map.keys(keys) -- ids == [],
               :sort_keys,
               "keys",
               "Sort keys contain unknown music IDs"
             ),
           {:ok, songs} <- rebuild(database, groups, keys, opts) do
        {:ok, %{database | songs: songs}}
      end

    Result.new(result, %{reindex: %{select: Keyword.get(opts, :select, :title)}})
  end

  ###
  ### Helpers
  ###

  defp groups(:title), do: ["title"]
  defp groups(:artist), do: ["artist"]
  defp groups(:both), do: ["title", "artist"]

  defp rebuild(database, groups, keys, opts) do
    Enum.reduce_while(groups, {:ok, database.songs}, fn group, {:ok, songs} ->
      case rebuild_group(%{database | songs: songs}, group, keys, opts) do
        {:ok, songs} -> {:cont, {:ok, songs}}
        error -> {:halt, error}
      end
    end)
  end

  defp rebuild_group(database, group, keys, opts) do
    prefix = if group == "title", do: "", else: "artist_"
    rank_field = prefix <> "order_ascii"
    names = Enum.map(Schema.song_fields(database.format, database.schema_version), & &1.name)

    with :ok <-
           Validation.check(
             rank_field in names,
             :sort_keys,
             group,
             "Selected schema has no #{group} ranks"
           ),
         {:ok, entries} <- Validation.map(database.songs, &entry(&1, group, keys, opts)) do
      ascii = ranks(entries, :ascii, group)
      kana = entries |> Enum.reject(&is_nil(&1.kana)) |> ranks(:kana, group)

      {:ok,
       Enum.zip_with(database.songs, entries, fn song, entry ->
         Map.merge(song, %{
           (prefix <> "order_ascii") => ascii[entry.id],
           (prefix <> "order_kana") => Map.get(kana, entry.id, 0),
           (prefix <> "category_kana") => entry.category
         })
       end)}
    end
  end

  defp entry(song, group, keys, opts) do
    id = song["music_id"]
    record = Map.get(keys, Integer.to_string(id), %{})

    with :ok <- key_object(record, ["title", "artist"], "keys", id),
         supplied = Map.get(record, group, %{}),
         :ok <- key_object(supplied, ["ascii", "kana", "category"], group, id) do
      stored = if group == "title", do: "title_ascii", else: "artist_title_ascii"

      ascii =
        Map.get(
          supplied,
          "ascii",
          if(Keyword.get(opts, :use_stored_keys, false), do: song[stored])
        )

      kana = supplied["kana"]

      with :ok <-
             Validation.check(
               is_binary(ascii) and String.valid?(ascii),
               :sort_keys,
               group <> ".ascii",
               "Supply ASCII sort keys for every record, or use --use-stored-keys",
               id
             ),
           :ok <- validate_kana(kana, group, id),
           :ok <-
             Validation.check(
               not Map.has_key?(supplied, "category") or kana != nil,
               :sort_keys,
               group <> ".category",
               "A category requires a kana key",
               id
             ),
           {:ok, category} <- category(kana, supplied["category"], id),
           :ok <- clear_kana(song, group, kana, opts) do
        {:ok,
         %{
           id: id,
           ascii: ascii,
           kana: kana,
           category: category,
           complete: Map.has_key?(supplied, "ascii")
         }}
      end
    end
  end

  defp clear_kana(song, group, nil, opts) do
    prefix = if group == "title", do: "", else: "artist_"

    Validation.check(
      Keyword.get(opts, :clear_missing_kana, false) or
        (song[prefix <> "order_kana"] == 0 and song[prefix <> "category_kana"] == 0),
      :sort_keys,
      group <> ".kana",
      "Supply a kana key or use --clear-missing-kana to clear existing kana ranks and categories",
      song["music_id"]
    )
  end

  defp clear_kana(_song, _group, _kana, _opts), do: :ok

  defp key_object(value, keys, path, id) do
    Validation.check(
      is_map(value) and Map.keys(value) -- keys == [],
      :sort_keys,
      path,
      "Unexpected sort key object fields",
      id
    )
  end

  defp validate_kana(nil, _group, _id), do: :ok

  defp validate_kana(value, group, id) do
    Validation.check(
      is_binary(value) and String.valid?(value) and value != "",
      :sort_keys,
      group <> ".kana",
      "Expected nonempty kana key",
      id
    )
  end

  defp category(nil, nil, _id), do: {:ok, 0}
  defp category(kana, <<code>>, id), do: category(kana, code, id)
  defp category(_kana, code, _id) when code in ~c"AKSTNHMYRW", do: {:ok, code}

  defp category(_kana, _code, id) do
    {:error,
     Result.diagnostic(
       :sort_keys,
       "category",
       "Kana keys require a category code: A K S T N H M Y R W",
       id
     )}
  end

  defp ranks(entries, field, group) do
    entries
    |> Enum.sort_by(&{Map.fetch!(&1, field), &1.id})
    |> Enum.reduce({%{}, %{}, 0}, fn entry, {ranks, shared, last} ->
      key = {entry.ascii, entry.kana, entry.category}

      existing =
        if group == "artist" and entry.complete do
          Map.get(shared, key)
        end

      rank = existing || last + 1

      {Map.put(ranks, entry.id, rank),
       if(entry.complete, do: Map.put(shared, key, rank), else: shared), max(last, rank)}
    end)
    |> elem(0)
  end
end
