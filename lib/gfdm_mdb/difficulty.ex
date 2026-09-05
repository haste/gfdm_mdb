defmodule GfdmMdb.Difficulty do
  @moduledoc "Canonical difficulty families, instruments and integer levels in native order."

  alias GfdmMdb.Schema.Field

  @spec field(:classic | :modern) :: Field.t()
  def field(family) do
    {parts, levels, type} = layout(family)

    Field.object(
      Atom.to_string(family),
      Enum.map(parts, fn part ->
        Field.object(part, Enum.map(levels, &Field.new(&1, type, 1)))
      end)
    )
  end

  defp layout(:classic), do: {~w(guitar bass open drum), ~w(beginner basic advanced extreme), :u8}
  defp layout(:modern), do: {~w(guitar drum bass), ~w(novice basic advanced extreme master), :u16}
end
