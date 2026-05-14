defmodule SymphonyElixirWeb.PublicPath do
  @moduledoc false

  alias SymphonyElixirWeb.Endpoint

  @spec base_path() :: String.t()
  def base_path do
    Endpoint.config(:base_path) || ""
  end

  @spec path(String.t()) :: String.t()
  def path(path), do: path(base_path(), path)

  @spec path(String.t(), String.t()) :: String.t()
  def path("", path), do: normalize_path(path)
  def path(base_path, path), do: base_path <> normalize_path(path)

  defp normalize_path("/" <> _ = path), do: path
  defp normalize_path(path), do: "/" <> path
end
