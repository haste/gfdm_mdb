defmodule GfdmMdb.Cli.Arguments do
  @moduledoc "Adapts argparse results and enforces MDB command relationships."

  alias GfdmMdb.Cli.{Definition, RecordPatch}
  alias GfdmMdb.Codec.Json
  alias GfdmMdb.{File, Result, Schema, Validation}

  @type request :: %{
          command: String.t(),
          input: Path.t(),
          options: map()
        }
  @type result ::
          {:ok, :help | {:help, String.t()} | request()}
          | {:error, Result.diagnostic(), map()}

  @spec parse([String.t()]) :: result()
  def parse([]), do: {:ok, :help}
  def parse([arg]) when arg in ["help", "--help", "-h"], do: {:ok, :help}
  def parse(["help", command]), do: parse([command, "--help"])

  def parse(arguments) do
    case parse_arguments(arguments) do
      {:ok, parsed, [_program, command], _definition} ->
        normalize(to_string(command), parsed)

      {:error, reason} ->
        {_, error} = usage(reason |> :argparse.format_error() |> IO.chardata_to_string())
        {:error, error, json_option(arguments)}

      {:ok, _parsed, _path, _definition} ->
        {_, error} = usage("Choose a command; see --help")
        {:error, error, json_option(arguments)}
    end
  end

  @spec help(String.t() | nil) :: IO.chardata()
  def help(command \\ nil) do
    path = if command, do: [String.to_charlist(command)], else: []

    :argparse.help(Definition.cli(true, command), %{
      progname: ~c"gfdm_mdb",
      command: path,
      # argparse adds two leading spaces to usage lines beyond this width.
      columns: 78
    })
  end

  @spec resolve(request(), GfdmMdb.encoding()) :: request()
  def resolve(request, encoding) do
    opts = request.options
    path = if opts[:in_place], do: request.input, else: opts[:output]

    output_encoding = opts[:output_format] || infer_encoding(opts, encoding, path)

    opts =
      Map.merge(opts, %{
        output: path,
        force: opts[:in_place] || opts[:force] || false,
        input_encoding: encoding
      })

    opts =
      if output_encoding,
        do: Map.put(opts, :encoding, output_encoding),
        else: opts

    %{request | options: opts}
  end

  @spec load(request(), GfdmMdb.Database.t()) :: GfdmMdb.result(request())
  def load(request, database) do
    with {:ok, options} <- Validation.map(Map.to_list(request.options), &load_option/1),
         {:ok, options} <- patch(request.command, Map.new(options), database) do
      {:ok, %{request | options: options}}
    end
  end

  @spec usage(String.t()) :: {:error, Result.diagnostic()}
  def usage(message), do: {:error, Result.diagnostic(:usage, "", message)}

  @spec input_options(map(), GfdmMdb.encoding()) :: :ok | {:error, Result.diagnostic()}
  def input_options(opts, encoding) do
    if opts[:input_schema_version] && encoding != :xml,
      do: usage("--input-schema-version requires an XML input"),
      else: :ok
  end

  @spec output_options(map(), GfdmMdb.Database.t()) :: :ok | {:error, Result.diagnostic()}
  def output_options(opts, database) do
    format = if opts[:target], do: elem(opts[:target], 0), else: database.format
    encoding = opts[:encoding] || Schema.native_encoding(format)

    if Map.has_key?(opts, :identity) and encoding != :json,
      do:
        usage("--identity requires JSON output; use --output-format json or a .json output file"),
      else: :ok
  end

  ###
  ### Helpers
  ###

  defp infer_encoding(opts, encoding, path) do
    if opts[:in_place] do
      if !opts[:target] or encoding == :json, do: encoding
    else
      Map.get(%{".json" => :json, ".xml" => :xml, ".bin" => :binary}, Path.extname(path || ""))
    end
  end

  defp request(command, input, opts) do
    target =
      if opts[:target] do
        [format | version] = String.split(opts[:target], ":")
        {String.to_integer(format), if(version != [], do: String.to_integer(hd(version)))}
      end

    %{
      command: command,
      input: input,
      options: Map.put(opts, :target, target)
    }
  end

  defp load_option({key, path}) when key in [:record, :patch, :defaults, :overrides, :keys] do
    with {:ok, bytes} <- File.read(path),
         {:ok, value} <- Json.parse(bytes),
         do: {:ok, {key, value}}
  end

  defp load_option(option), do: {:ok, option}

  defp patch(command, opts, database) when command in ["edit", "clone"] do
    with {:ok, patch} <- RecordPatch.build(database, opts) do
      {:ok, opts |> Map.delete(:set) |> Map.put(:patch, patch)}
    end
  end

  defp patch(_command, opts, _database), do: {:ok, opts}

  defp parse_arguments(arguments) do
    result = :argparse.parse(arguments, Definition.cli(), %{progname: ~c"gfdm_mdb"})

    case result do
      {:error, {_path, _expected, :undefined, _details}} ->
        case :argparse.parse(arguments, Definition.cli(false), %{progname: ~c"gfdm_mdb"}) do
          {:ok, %{help: true}, _path, _definition} = help -> help
          _other -> result
        end

      _other ->
        result
    end
  end

  defp normalize(command, parsed) do
    {input, opts} = Map.pop(parsed, :input, [])

    kind = if command == "inspect" and opts[:records], do: :all, else: :songs

    result =
      if opts[:help] do
        {:ok, {:help, command}}
      else
        with :ok <- input(command, input),
             :ok <- destination(command, opts),
             :ok <- constraints(command, opts) do
          {:ok, request(command, hd(input), Map.put_new(opts, :kind, kind))}
        end
      end

    case result do
      {:error, error} -> {:error, error, opts}
      result -> result
    end
  end

  defp input(_command, [_path]), do: :ok

  defp input(command, _paths), do: usage("#{command} requires exactly INPUT")

  defp destination(command, opts) do
    cond do
      opts[:in_place] && opts[:output] -> usage("Choose --in-place or --output")
      Definition.command(command).output == :none -> :ok
      opts[:dry_run] || opts[:in_place] || opts[:output] -> :ok
      true -> usage("Missing --output")
    end
  end

  defp constraints("inspect", opts) do
    cond do
      opts[:records] && opts[:id] ->
        usage("Choose --records or --id")

      opts[:kind] && !(opts[:records] || opts[:id]) ->
        usage("--kind requires --records or --id when inspecting")

      true ->
        :ok
    end
  end

  defp constraints("convert", opts) do
    if opts[:target] == nil and
         Enum.any?([:defaults, :overrides, :allow_loss], &Map.has_key?(opts, &1)),
       do: usage("Conversion defaults, overrides, and loss permission require --target"),
       else: :ok
  end

  defp constraints("edit", opts) do
    if Enum.any?([:patch, :set], &Map.has_key?(opts, &1)),
      do: :ok,
      else: usage("Edit requires --patch or --set")
  end

  defp constraints(_command, _opts), do: :ok

  defp json_option(arguments) do
    arguments = Enum.take_while(arguments, &(&1 != "--"))
    {opts, _args, _invalid} = OptionParser.parse(arguments, strict: [json: :boolean])
    Map.new(opts)
  end
end
