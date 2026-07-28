defmodule PrintableBinaryTest do
  use ExUnit.Case, async: true
  import PrintableBinary
  doctest PrintableBinary

  test "~PB decodes passthrough ASCII to itself" do
    assert ~PB"AB" == "AB"
  end

  test "~PB decodes control-char glyphs (byte 0 -> ·)" do
    assert PrintableBinary.decode("·") == <<0>>
  end

  test "whitespace inside the sigil is ignored (heredoc/wrapping-safe)" do
    assert ~PB"A B" == "AB"
    assert ~PB"""
           A
           B
           """ == "AB"
  end

  test "decode/1 round-trips all 256 single-byte glyphs" do
    # Build the inverse (byte -> glyph) from the same source, then decode each glyph.
    byte_to_glyph =
      Path.expand("../../character_map.txt", __DIR__)
      |> File.read!()
      |> String.split("\n")
      |> Enum.map(&String.trim_trailing(&1, "\r"))
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "##")))
      |> Enum.map(&(&1 |> String.split() |> hd()))

    assert length(byte_to_glyph) == 256

    for {glyph, byte} <- Enum.with_index(byte_to_glyph) do
      assert PrintableBinary.decode(glyph) == <<byte>>, "byte #{byte} glyph #{inspect(glyph)}"
    end
  end

  test "unrecognized glyph raises" do
    assert_raise ArgumentError, fn -> PrintableBinary.decode("🚫") end
  end
end
