defmodule PrintableBinary.MixProject do
  use Mix.Project

  def project do
    [
      app: :printable_binary,
      version: "0.1.0",
      elixir: "~> 1.15",
      description: "Compile-time ~PB sigil: printable-binary glyphs -> raw binary",
      deps: []
    ]
  end

  def application, do: []
end
