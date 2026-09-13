defmodule GfdmMdb.Schema.Field do
  @moduledoc "Typed field declarations, defaults, and value validation."

  import Bitwise
  alias GfdmMdb.Validation

  @type integer_type :: :bool | :u8 | :u16 | :u32 | :s8 | :s16 | :s32
  @type field_type :: integer_type() | :hex | :title | :str | :object | :union
  @type value :: integer() | String.t() | [integer()] | %{String.t() => value()} | nil
  @type t :: %__MODULE__{
          name: String.t(),
          type: field_type(),
          count: pos_integer(),
          fields: [t()],
          optional: boolean()
        }

  defstruct [:name, :type, :count, fields: [], optional: false]

  @spec new(String.t(), field_type(), pos_integer()) :: t()
  def new(name, type, count) do
    %__MODULE__{name: name, type: type, count: count}
  end

  @spec object(String.t(), [t()]) :: t()
  def object(name, fields), do: %__MODULE__{name: name, type: :object, count: 1, fields: fields}

  @spec width(t()) :: pos_integer()
  def width(%{type: :object, fields: fields}), do: Enum.sum_by(fields, &width/1)
  def width(%{type: type, count: count}) when type in [:hex, :title], do: count
  def width(%{type: type, count: count}), do: div(bits(type), 8) * count

  @spec bounds(integer_type()) :: {integer(), integer()}
  def bounds(:bool) do
    {0, 1}
  end

  def bounds(type) when type in [:u8, :u16, :u32] do
    {0, (1 <<< bits(type)) - 1}
  end

  def bounds(type) when type in [:s8, :s16, :s32] do
    {-(1 <<< (bits(type) - 1)), (1 <<< (bits(type) - 1)) - 1}
  end

  @spec bits(integer_type()) :: 8 | 16 | 32
  def bits(type) when type in [:bool, :u8, :s8] do
    8
  end

  def bits(type) when type in [:u16, :s16] do
    16
  end

  def bits(type) when type in [:u32, :s32] do
    32
  end

  @spec neutral(t()) :: value()
  def neutral(%{type: :object, fields: fields}) do
    Map.new(fields, &{&1.name, neutral(&1)})
  end

  def neutral(%{type: :union, fields: [field | _rest]}), do: neutral(field)

  def neutral(%{type: :hex, count: count}) do
    String.duplicate("00", count)
  end

  def neutral(%{type: type}) when type in [:str, :title] do
    ""
  end

  def neutral(%{count: 1}) do
    0
  end

  def neutral(%{count: count}) do
    List.duplicate(0, count)
  end

  @spec validate(t(), term(), String.t(), integer() | nil) ::
          :ok | {:error, GfdmMdb.Result.diagnostic()}
  def validate(field, value, path, id \\ nil)

  def validate(%{optional: true}, nil, _path, _id), do: :ok

  def validate(%{type: :object, fields: fields}, value, path, id) do
    Validation.validate_record(value, fields, path, id)
  end

  def validate(%{type: :union, fields: fields} = field, value, path, id) do
    if valid?(field, value),
      do: :ok,
      else: validate(hd(fields), value, path, id)
  end

  def validate(%{type: :title} = field, value, path, id) do
    Validation.check(
      valid?(field, value),
      :title,
      path,
      "Title must be valid UTF-8, contain no NUL, and use at most #{field.count - 1} bytes",
      id
    )
  end

  def validate(field, value, path, id) do
    Validation.check(
      valid?(field, value),
      :invalid_value,
      path,
      "Expected #{field.type} with count #{field.count}",
      id
    )
  end

  @spec valid?(t(), term()) :: boolean()
  def valid?(%{optional: true}, nil), do: true

  def valid?(%{type: :union, fields: fields}, value) do
    Enum.any?(fields, &valid?(&1, value))
  end

  def valid?(%{type: :object, fields: fields}, value) do
    Validation.validate_record(value, fields, "") == :ok
  end

  def valid?(%{type: :hex, count: count}, value) when is_binary(value) do
    case Base.decode16(value, case: :mixed) do
      {:ok, bytes} -> byte_size(bytes) == count
      :error -> false
    end
  end

  def valid?(%{type: :title, count: count}, value) do
    is_binary(value) and String.valid?(value) and byte_size(value) < count and
      not String.contains?(value, <<0>>)
  end

  def valid?(%{type: :str}, value) do
    is_binary(value) and String.valid?(value)
  end

  def valid?(%{type: :hex}, _value) do
    false
  end

  def valid?(%{count: count} = field, value) when count > 1 do
    is_list(value) and length(value) == count and
      Enum.all?(value, &valid?(%{field | count: 1}, &1))
  end

  def valid?(%{type: type}, value) do
    {minimum, maximum} = bounds(type)
    is_integer(value) and value >= minimum and value <= maximum
  end
end
