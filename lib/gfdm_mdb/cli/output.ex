defmodule GfdmMdb.Cli.Output do
  @moduledoc "Renders MDB command results and help as text or JSON."

  alias GfdmMdb.Cli.Arguments
  alias GfdmMdb.Codec.Json
  alias GfdmMdb.Result

  @spec help(String.t() | nil) :: :ok
  def help(command \\ nil), do: IO.write(Arguments.help(command))

  @spec inspection(GfdmMdb.Database.t(), map()) :: :ok | nil
  def inspection(database, opts) do
    if opts[:json] do
      excluded =
        for kind <- [:songs, :courses],
            !opts[:records] or opts[:kind] not in [:all, kind],
            do: Atom.to_string(kind)

      database
      |> Json.envelope()
      |> Map.drop(excluded)
      |> Map.put("input_encoding", opts[:input_encoding])
      |> Map.put("counts", %{songs: length(database.songs), courses: length(database.courses)})
      |> json()
    else
      summary(database, opts[:input_encoding])
      if opts[:records], do: records(database, opts[:kind])
    end
  end

  @spec verification(GfdmMdb.Validation.report(), map()) :: :ok
  def verification(report, opts) do
    if opts[:json] do
      json(report)
    else
      IO.puts(
        "#{if report.valid, do: "Valid", else: "Failed"}: #{length(report.errors)} errors, #{length(report.warnings)} warnings"
      )

      IO.write(:stderr, diagnostics_text(report.warnings))
    end
  end

  @spec json(term()) :: :ok
  def json(value), do: value |> Json.pretty() |> IO.write()

  @spec record(GfdmMdb.Database.record_data(), map()) :: :ok
  def record(record, opts) do
    if opts[:json], do: json(record), else: record_text(record)
  end

  defp record_text(record, prefix \\ ""),
    do:
      record
      |> Enum.sort()
      |> Enum.each(fn {key, value} -> record_value(prefix <> key, value) end)

  defp record_value(key, value) when is_map(value), do: record_text(value, key <> ".")

  defp record_value("chart_list" = key, values) when is_list(values) do
    IO.puts("#{key}:")
    Enum.each(Enum.chunk_every(values, 8), &IO.puts("  " <> Enum.join(&1, " ")))
  end

  defp record_value(key, values) when is_list(values),
    do: IO.puts("#{key}: #{Enum.join(values, " ")}")

  defp record_value(key, value), do: IO.puts("#{key}: #{text(value)}")

  @spec result(Result.t(), map(), Path.t() | nil) :: :ok
  def result(result, opts, output \\ nil) do
    report = output_report(result, opts, output)

    if opts[:json] do
      json(report)
    else
      device = if Result.valid?(result), do: :stdio, else: :stderr

      if result.reports[:conversion],
        do: IO.write(device, conversion_text(result.reports.conversion))

      IO.write(device, Enum.map(result.changes, &change_text/1))
      IO.write(:stderr, diagnostics_text(result.errors ++ result.warnings))

      completion(report, opts, output)
    end
  end

  ###
  ### Helpers
  ###

  defp output_report(result, opts, output) do
    report = Result.report(result)

    if result.bytes do
      destination = if opts[:dry_run], do: %{dry_run: true}, else: %{output: output}

      Map.merge(
        report,
        Map.merge(destination, %{bytes: byte_size(result.bytes), unchanged: result.changes == []})
      )
    else
      report
    end
  end

  defp completion(%{bytes: bytes} = report, opts, output) do
    if report.unchanged, do: IO.puts("No record values changed.")

    IO.puts(
      if opts[:dry_run],
        do: "Dry run: valid output, #{bytes} bytes.",
        else: "Wrote #{output} (#{bytes} bytes)."
    )
  end

  defp completion(_report, _opts, _output), do: :ok

  @spec summary(GfdmMdb.Database.t(), GfdmMdb.encoding()) :: :ok
  defp summary(database, encoding) do
    IO.puts("Input encoding: #{encoding |> to_string() |> String.upcase()}")
    IO.puts("Format: #{database.format}")
    if database.schema_version, do: IO.puts("Version: #{database.schema_version}")
    if database.identity, do: IO.puts("Identity: #{database.identity}")

    storage =
      cond do
        database.format == 203 -> "XML"
        database.encrypted -> "MDBE (encrypted binary)"
        true -> "MDB (plain binary)"
      end

    IO.puts(
      "Native storage: #{storage}\nSongs: #{length(database.songs)}\nCourses: #{length(database.courses)}"
    )
  end

  @spec records(GfdmMdb.Database.t(), GfdmMdb.Database.kind() | :all) :: :ok
  defp records(database, :all) do
    records(database, :songs)
    records(database, :courses)
  end

  defp records(database, :songs) do
    IO.puts("\nSongs")

    songs =
      Enum.map(database.songs, fn song ->
        title =
          case song["title_name"] do
            value when is_binary(value) and value != "" -> value
            _value -> song["title_ascii"]
          end

        bpm =
          if song["bpm2"] == 0, do: to_string(song["bpm"]), else: "#{song["bpm"]}-#{song["bpm2"]}"

        [song["music_id"], bpm, title]
      end)

    table(["ID", "BPM", "Title"], songs)
  end

  defp records(database, :courses) do
    IO.puts("\nCourses")

    courses =
      Enum.map(
        database.courses,
        &[&1["course_id"], &1["course_flag"], Enum.join(&1["music_ids"], ", ")]
      )

    table(["ID", "Flags", "Song IDs"], courses)
  end

  defp table(headers, []) do
    IO.puts(Enum.join(headers, "  "))
    IO.puts("  (none)")
  end

  defp table(headers, rows) do
    rows
    |> Enum.map(&Map.new(Enum.with_index(&1), fn {value, index} -> {index, value} end))
    |> Owl.Table.new(
      border_style: :none,
      padding_x: 1,
      max_width: :infinity,
      render_cell: [header: &Enum.at(headers, &1), body: &text/1]
    )
    |> Owl.IO.puts()
  end

  defp text(value) do
    value
    |> to_string()
    |> String.replace("\r", "\\r")
    |> String.replace("\n", "\\n")
    |> String.replace("\t", "\\t")
  end

  defp conversion_text(report) do
    target = report.target
    version = if target.schema_version, do: ", version #{target.schema_version}", else: ""

    "Conversion to format #{target.format}#{version}\n" <>
      Enum.map_join(report.issues, "", fn issue ->
        "  #{issue.kind}: #{location(issue)}#{issue.message}\n"
      end)
  end

  defp diagnostics_text(issues) do
    Enum.map_join(issues, "", &"#{&1.code}: #{location(&1)}#{&1.message}\n")
  end

  defp change_text(change) do
    [
      "#{change.action |> to_string() |> String.capitalize()} #{change.kind} [ID #{change.record_id}]\n",
      change
      |> Map.get(:fields, %{})
      |> Enum.sort()
      |> Enum.map(fn {field, values} ->
        "  #{field}: #{JSON.encode!(values.before)} -> #{JSON.encode!(values.after)}\n"
      end)
    ]
  end

  defp location(issue) do
    id = if issue.record_id != nil, do: " [ID #{issue.record_id}]", else: ""
    path = (issue.path || "") <> id
    if path == "", do: "", else: path <> ": "
  end
end
