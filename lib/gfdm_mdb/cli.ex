defmodule GfdmMdb.Cli do
  @moduledoc "Loads the command input, prepares output, and installs successful results."

  alias GfdmMdb.Cli.{Arguments, Output}
  alias GfdmMdb.{Database, File, Result, Validation}

  @spec main([String.t()]) :: no_return()
  def main(arguments), do: arguments |> run() |> System.halt()

  @spec run([String.t()]) :: non_neg_integer()
  def run(arguments) do
    case Arguments.parse(arguments) do
      {:ok, :help} ->
        Output.help()
        0

      {:ok, {:help, command}} ->
        Output.help(command)
        0

      {:ok, request} ->
        execute(request) |> finish(request.options)

      {:error, error, opts} ->
        finish({:error, error}, opts)
    end
  end

  ###
  ### Helpers
  ###

  defp finish({:ok, code}, _opts), do: code

  defp finish({:error, error}, opts) do
    Output.result(Result.error(error), opts)
    if error.code == :usage, do: 2, else: 1
  end

  defp execute(request) do
    with {:ok, bytes} <- File.read(request.input),
         encoding = GfdmMdb.detect_encoding(bytes),
         {:ok, database} <- GfdmMdb.decode(bytes, read_options(request.options, encoding)),
         :ok <- Arguments.input_options(request.options, encoding),
         request = Arguments.resolve(request, encoding),
         :ok <- Arguments.output_options(request.options, database) do
      dispatch(request, database)
    end
  end

  defp read_options(opts, encoding) do
    opts
    |> Map.take([:identity])
    |> Map.to_list()
    |> Keyword.merge(encoding: encoding, schema_version: opts[:input_schema_version])
  end

  defp dispatch(%{command: "inspect"} = request, database) do
    opts = request.options

    if opts[:id] != nil do
      with {:ok, record} <- Database.fetch(database, opts[:id], opts[:kind]) do
        Output.record(record, opts)

        {:ok, 0}
      end
    else
      Output.inspection(database, opts)

      {:ok, 0}
    end
  end

  defp dispatch(%{command: "verify"} = request, database) do
    report =
      Validation.compatibility_report(database, strict: request.options[:strict] || false)

    Output.verification(report, request.options)
    {:ok, if(report.valid, do: 0, else: 1)}
  end

  defp dispatch(request, database) do
    with {:ok, request} <- Arguments.load(request, database) do
      result =
        database
        |> GfdmMdb.transform(request.command, Map.to_list(request.options))
        |> install(request.options)

      Output.result(result, request.options, request.options.output)
      {:ok, if(Result.valid?(result), do: 0, else: 1)}
    end
  end

  defp install(%Result{errors: [], bytes: bytes} = result, opts) when is_binary(bytes) do
    if opts[:dry_run] do
      result
    else
      case File.write(opts.output, bytes, opts.force) do
        :ok -> result
        {:error, error} -> Result.error(error, result)
      end
    end
  end

  defp install(result, _request), do: result
end
