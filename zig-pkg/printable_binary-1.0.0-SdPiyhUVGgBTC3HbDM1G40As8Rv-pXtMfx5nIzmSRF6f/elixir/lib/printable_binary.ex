defmodule PrintableBinary do
  @moduledoc """
  Compile-time `~PB` sigil that decodes printable-binary glyphs into a raw binary
  at COMPILE time — so binary data can be embedded legibly inline in source (no
  separate fixture files), with zero runtime cost (the bytes are baked into the
  BEAM).

      import PrintableBinary
      @magic ~PB"..."   # decoded to raw bytes at compile time
  """

  @map_path Path.expand("../../character_map.txt", __DIR__)
  @external_resource @map_path

  # byte<->glyph map parsed from the single-source character_map.txt at compile time
  # (same parse rules as every other implementation: `##` = comment, first
  # whitespace-delimited token per line is the glyph, in byte order).
  @glyph_to_byte @map_path
                 |> File.read!()
                 |> String.split("\n")
                 |> Enum.map(&String.trim_trailing(&1, "\r"))
                 |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "##")))
                 |> Enum.map(&(&1 |> String.split() |> hd()))
                 |> Enum.with_index()
                 |> Map.new(fn {glyph, byte} -> {glyph, byte} end)

  @doc """
  Decode a printable-binary string to a raw binary. Whitespace is ignored (the
  encoding never emits literal whitespace), so wrapped / heredoc input works.
  Raises `ArgumentError` on an unrecognized glyph.
  """
  @spec decode(binary()) :: binary()
  def decode(string) when is_binary(string) do
    string
    |> String.replace(~r/[ \t\r\n]/, "")
    |> String.codepoints()
    |> Enum.map(fn cp ->
      case Map.fetch(@glyph_to_byte, cp) do
        {:ok, byte} -> byte
        :error -> raise ArgumentError, "invalid printable-binary glyph: #{inspect(cp)}"
      end
    end)
    |> :erlang.list_to_binary()
  end

  @doc ~S'''
  The `~PB` sigil: decodes printable-binary content to a raw binary at compile
  time. Use `"..."` or a `"""` heredoc (a literal `"` never appears in the
  payload, so it can't close the sigil early).

      iex> import PrintableBinary
      iex> ~PB"AB"
      "AB"
  '''
  defmacro sigil_PB({:"<<>>", _meta, [string]}, _modifiers) when is_binary(string) do
    decode(string)
  end
end
