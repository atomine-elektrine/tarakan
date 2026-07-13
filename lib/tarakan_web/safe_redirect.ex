defmodule TarakanWeb.SafeRedirect do
  @moduledoc false

  @doc "Returns a same-origin absolute path or the supplied fallback."
  def local_path(path, fallback \\ "/")

  def local_path(path, fallback) when is_binary(path) do
    with true <- valid_path?(path),
         true <- decoded_paths_local?(path, 0) do
      path
    else
      _invalid -> fallback
    end
  end

  def local_path(_path, fallback), do: fallback

  defp valid_path?(path) do
    uri = URI.parse(path)

    String.starts_with?(path, "/") and
      not String.starts_with?(path, "//") and
      not String.contains?(path, "\\") and
      not String.match?(path, ~r/[\x00-\x1F\x7F]/) and
      is_nil(uri.scheme) and is_nil(uri.host) and is_nil(uri.userinfo)
  end

  # Browsers, proxies, and a subsequent request may each decode a path once.
  # Validate every encoded form instead of trusting only the first layer.
  defp decoded_paths_local?(_path, depth) when depth >= 8, do: false

  defp decoded_paths_local?(path, depth) do
    case decode(path) do
      {:ok, ^path} -> true
      {:ok, decoded} -> valid_path?(decoded) and decoded_paths_local?(decoded, depth + 1)
      :error -> false
    end
  end

  defp decode(path) do
    {:ok, URI.decode(path)}
  rescue
    ArgumentError -> :error
  end
end
