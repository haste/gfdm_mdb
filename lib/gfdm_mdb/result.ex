defmodule GfdmMdb.Result do
  @moduledoc "A transformation candidate, diagnostics, changes, and optional encoded output."

  alias GfdmMdb.Database

  @type diagnostic :: %{
          code: atom(),
          path: String.t(),
          record_id: integer() | nil,
          message: String.t()
        }

  @type t :: %__MODULE__{
          database: Database.t() | nil,
          errors: [diagnostic()],
          warnings: [diagnostic()],
          changes: [Database.change()],
          reports: map(),
          bytes: binary() | nil
        }

  defstruct [:database, :bytes, errors: [], warnings: [], changes: [], reports: %{}]

  @spec diagnostic(atom(), String.t(), String.t(), integer() | nil) :: diagnostic()
  def diagnostic(code, path, message, record_id \\ nil) do
    %{code: code, path: path, message: message, record_id: record_id}
  end

  @doc "Wraps an operation candidate. Use GfdmMdb.prepare/3 to validate and encode it."
  @spec new(GfdmMdb.result(Database.t()), map()) :: t()
  def new(outcome, reports \\ %{})
  def new({:ok, database}, reports), do: %__MODULE__{database: database, reports: reports}
  def new({:error, error}, reports), do: error(error, %__MODULE__{reports: reports})

  @spec error(diagnostic(), t()) :: t()
  def error(error, result \\ %__MODULE__{}) do
    %{result | errors: [error], bytes: nil}
  end

  @doc "Reports whether preparation produced bytes without errors."
  @spec valid?(t()) :: boolean()
  def valid?(result), do: result.errors == [] and is_binary(result.bytes)

  @spec report(t()) :: map()
  def report(result) do
    Map.merge(result.reports, %{
      valid: valid?(result),
      errors: result.errors,
      warnings: result.warnings,
      changes: result.changes
    })
  end
end
