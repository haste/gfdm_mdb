defmodule GfdmMdb.Codec.CipherTest do
  use ExUnit.Case, async: true

  alias GfdmMdb.Codec.Cipher

  test "MDBE encryption matches reference bytes across multiple mask periods" do
    plain = :binary.list_to_bin(Enum.to_list(0..255))

    # Generated in Python from the original quotient-based reference expression.
    # Fixed ciphertext catches errors that encrypt/decrypt round trips can hide.
    encrypted =
      Base.decode16!(
        "434B5B719587A1B1405A50628EAC9CB8564971796D87A7B55F4F72686694BCDE" <>
          "1276445BA7AFBF95796B4D5DA4BEB48672506044B2AD959D016B4B59BBAB968C" <>
          "7A0820C236D2E0FF0B031339DDCFE9F91802083AD6F4C4E01E01393125CFEFFD" <>
          "27370A101EECC4A65A3E0C13EFE7F7DD21331505FCE6ECDE3A18280CFAE5DDD5" <>
          "B9D3F3E103132E34B2C0E80AFE1A2837D3DBCBE105173121D0CAC0F21E3C0C28" <>
          "E6F9C1C9DD371705EFFFC2D8D6240C6E82E6D4CB373F2F05E9FBDDCD342E2416" <>
          "82A090B4425D656DF19BBBA94B5B667CEA98B052A642706F9B9383A94D5F7969" <>
          "A8B2B88A66447450AEB18981957F5F4DB7A79A808E7C5436CAAE9C837F77674D"
      )

    assert Cipher.encrypt(plain) == encrypted
    assert Cipher.decrypt(encrypted) == plain
  end
end
