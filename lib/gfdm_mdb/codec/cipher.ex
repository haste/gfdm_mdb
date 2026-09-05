defmodule GfdmMdb.Codec.Cipher do
  @moduledoc "The MDBE reverse/XOR transform."

  import Bitwise
  @key "2+.58>;.A"

  @spec decrypt(binary()) :: binary()
  def decrypt(stored) do
    transform(stored, byte_size(stored) - 1, -1, [])
  end

  @spec encrypt(binary()) :: binary()
  def encrypt(plain) do
    transform(plain, 0, 1, [])
  end

  ###
  ### Helpers
  ###

  # Mask positions refer to the plaintext.
  defp transform(<<>>, _index, _step, reversed), do: :binary.list_to_bin(reversed)

  defp transform(<<byte, rest::binary>>, index, step, reversed) do
    transform(rest, index + step, step, [bxor(byte, mask(index)) | reversed])
  end

  defp mask(index) do
    slot = rem(index, byte_size(@key))

    band(slot + 16 * rem(index, 8) + bxor(:binary.at(@key, slot), 127 - slot), 255)
  end
end
