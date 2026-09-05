defmodule GfdmMdb.File do
  @moduledoc "Atomic file writes with optional replacement of existing files."

  alias GfdmMdb.Result

  @spec read(Path.t()) :: GfdmMdb.result(binary())
  def read(path) do
    case File.read(path) do
      {:ok, bytes} ->
        {:ok, bytes}

      {:error, reason} ->
        {:error, Result.diagnostic(:file, path, to_string(:file.format_error(reason)))}
    end
  end

  @spec write(Path.t(), iodata(), boolean()) :: :ok | {:error, Result.diagnostic()}
  def write(path, bytes, force \\ false) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    temporary = path <> ".gfdm-mdb-#{suffix}.tmp"

    result =
      with {:ok, mode} <- destination(path, force), do: stage(temporary, path, bytes, force, mode)

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         Result.diagnostic(:file, path, "Cannot write output: #{:file.format_error(reason)}")}
    end
  end

  ###
  ### Helpers
  ###

  defp destination(path, force) do
    case File.lstat(path) do
      {:ok, %{type: :regular, mode: mode}} when force -> {:ok, Bitwise.band(mode, 0o777)}
      {:ok, _stat} -> {:error, :eexist}
      {:error, :enoent} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stage(temporary, path, bytes, force, mode) do
    result =
      File.open(temporary, [:write, :binary, :raw, :exclusive], fn file ->
        with :ok <- permissions(temporary, mode), do: write_and_sync(file, bytes)
      end)

    case result do
      {:ok, result} ->
        try do
          with :ok <- result, do: install(temporary, path, force)
        after
          File.rm(temporary)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp permissions(_path, nil), do: :ok
  defp permissions(path, mode), do: File.chmod(path, mode)

  defp write_and_sync(file, bytes) do
    with :ok <- :file.write(file, bytes), do: :file.sync(file)
  end

  defp install(temporary, path, true), do: File.rename(temporary, path)
  # A hard link prevents overwriting a concurrently created destination.
  defp install(temporary, path, false), do: File.ln(temporary, path)
end
