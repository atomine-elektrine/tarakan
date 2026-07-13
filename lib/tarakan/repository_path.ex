defmodule Tarakan.RepositoryPath do
  @moduledoc """
  Validation for repository-relative paths used at the GitHub and browser boundary.

  Paths remain byte-for-byte stable so they still identify the object at the
  pinned commit. Ambiguous filesystem syntax and control characters are
  rejected instead of normalized.
  """

  @max_bytes 500
  @max_segments 64

  @spec normalize(String.t() | nil) :: {:ok, String.t()} | {:error, :invalid_path}
  def normalize(nil), do: {:ok, ""}
  def normalize(""), do: {:ok, ""}

  def normalize(path) when is_binary(path) do
    segments = String.split(path, "/", trim: false)

    if String.valid?(path) and byte_size(path) <= @max_bytes and
         length(segments) <= @max_segments and
         not String.starts_with?(path, "/") and not String.ends_with?(path, "/") and
         not String.contains?(path, "\\") and not String.match?(path, ~r/[\x00-\x1F\x7F]/) and
         Enum.all?(segments, &valid_segment?/1) do
      {:ok, path}
    else
      {:error, :invalid_path}
    end
  end

  def normalize(_path), do: {:error, :invalid_path}

  defp valid_segment?(segment) do
    segment not in ["", ".", ".."] and byte_size(segment) <= 255
  end
end
