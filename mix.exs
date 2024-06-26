defmodule Librarian.MixProject do
  use Mix.Project

  def project do
    [
      app: :librarian,
      version: "0.2.0",
      elixir: "~> 1.9",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      package: [
        description: "stream-based ssh client",
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/ityonemo/librarian"}
      ],
      source_url: "https://github.com/ityonemo/librarian/",
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      docs: [main: "SSH", extras: ["README.md"]]
    ]
  end

  def application do
    [extra_applications: [:logger, :ssh]]
  end

  defp deps do
    [
      {:credo, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.22", only: :dev, runtime: false},
      {:excoveralls, "~> 0.13", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: :dev, runtime: false}
    ]
  end
end
