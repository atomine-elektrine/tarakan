defmodule Tarakan.RepositoryPath do
  @moduledoc """
  Validation and light canonicalization for repository-relative paths.

  Used at the GitHub and browser boundary and for finding `file` fields.
  Safe agent variants (`./lib/a.ex`, backslashes, duplicate slashes) are
  rewritten to a single form. Path traversal (`..`) and control characters
  are rejected. Case is preserved so paths still match the object at the
  pinned commit on case-sensitive trees.
  """

  @max_bytes 500
  @max_segments 64

  @spec normalize(String.t() | nil) :: {:ok, String.t()} | {:error, :invalid_path}
  def normalize(nil), do: {:ok, ""}
  def normalize(""), do: {:ok, ""}

  def normalize(path) when is_binary(path) do
    # Absolute paths are never repository-relative (reject before stripping "/").
    if String.starts_with?(String.trim(path), "/") do
      {:error, :invalid_path}
    else
      case canonicalize_segments(path) do
        {:ok, ""} ->
          {:ok, ""}

        {:ok, cleaned} ->
          segments = String.split(cleaned, "/", trim: false)

          if String.valid?(cleaned) and byte_size(cleaned) <= @max_bytes and
               length(segments) <= @max_segments and
               not String.match?(cleaned, ~r/[\x00-\x1F\x7F]/) and
               Enum.all?(segments, &valid_segment?/1) do
            {:ok, cleaned}
          else
            {:error, :invalid_path}
          end

        :error ->
          {:error, :invalid_path}
      end
    end
  end

  def normalize(_path), do: {:error, :invalid_path}

  @doc """
  Canonical string form used for fingerprinting (always lowercased).
  """
  @spec fingerprint_form(String.t() | nil) :: String.t()
  def fingerprint_form(nil), do: ""

  def fingerprint_form(path) when is_binary(path) do
    case canonicalize_segments(path) do
      {:ok, cleaned} -> String.downcase(cleaned)
      :error -> ""
    end
  end

  def fingerprint_form(_), do: ""

  defp canonicalize_segments(path) do
    segments =
      path
      |> String.trim()
      |> String.replace("\\", "/")
      |> String.split("/", trim: true)

    cond do
      Enum.any?(segments, &(&1 == "..")) ->
        :error

      true ->
        cleaned =
          segments
          |> Enum.reject(&(&1 in ["", "."]))
          |> Enum.join("/")

        {:ok, cleaned}
    end
  end

  defp valid_segment?(segment) do
    segment not in ["", ".", ".."] and byte_size(segment) <= 255
  end
end
