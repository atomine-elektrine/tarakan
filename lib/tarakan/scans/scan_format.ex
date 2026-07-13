defmodule Tarakan.Scans.ScanFormat do
  @moduledoc """
  Parser for Tarakan Scan Format v1, the canonical document a scan harness
  emits.

  A document is a JSON object with `"tarakan_scan_format": 1` and a
  `"findings"` array; an empty array means only that this review reported no
  findings for its pinned commit and declared scope.
  Unknown keys are ignored for forward compatibility. Scan metadata (commit
  SHA, model, prompt version) travels in the submission envelope, not in the
  document, so harness output stays reusable across submissions.
  """

  @format_version 1
  @severities ~w(critical high medium low info)
  @max_findings 200
  @max_line 1_000_000

  alias Tarakan.RepositoryPath

  def severities, do: @severities
  def max_findings, do: @max_findings

  @doc """
  Parses a scan document into finding attribute maps.

  `nil` and blank input parse as an empty findings list: `{:ok, []}`.
  """
  @spec parse(String.t() | nil) :: {:ok, [map()]} | {:error, String.t()}
  def parse(nil), do: {:ok, []}

  def parse(json) when is_binary(json) do
    if String.trim(json) == "" do
      {:ok, []}
    else
      case Jason.decode(json) do
        {:ok, document} -> parse_document(document)
        {:error, _error} -> {:error, "is not valid JSON"}
      end
    end
  end

  # Product language alias: Review Format == Scan Format v1.
  defp parse_document(%{"tarakan_review_format" => version} = document) do
    document
    |> Map.delete("tarakan_review_format")
    |> Map.put("tarakan_scan_format", version)
    |> parse_document()
  end

  defp parse_document(%{"tarakan_scan_format" => @format_version} = document) do
    case Map.fetch(document, "findings") do
      {:ok, findings} when is_list(findings) ->
        if length(findings) > @max_findings do
          {:error, "must contain at most #{@max_findings} findings"}
        else
          parse_findings(findings)
        end

      {:ok, _other} ->
        {:error, "findings must be a list"}

      :error ->
        {:error, "must include a findings list"}
    end
  end

  defp parse_document(%{"tarakan_scan_format" => _other}),
    do: {:error, "tarakan_scan_format must be #{@format_version}"}

  defp parse_document(%{}),
    do:
      {:error,
       ~s(must include "tarakan_scan_format" or "tarakan_review_format": #{@format_version})}

  defp parse_document(_other), do: {:error, "must be a JSON object"}

  defp parse_findings(findings) do
    findings
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {finding, index}, {:ok, parsed} ->
      case parse_finding(finding, index) do
        {:ok, attrs} -> {:cont, {:ok, [attrs | parsed]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp parse_finding(finding, index) when is_map(finding) do
    with {:ok, file_path} <- required_string(finding, "file", index),
         {:ok, file_path} <- repository_path(file_path, index),
         {:ok, severity} <- finding_severity(finding, index),
         {:ok, title} <- required_string(finding, "title", index),
         {:ok, description} <- required_string(finding, "description", index),
         {:ok, disposition} <- optional_disposition(finding, index),
         {:ok, canonical_public_id} <- optional_canonical_public_id(finding, index),
         {:ok, line_start} <- optional_line(finding, "line_start", index),
         {:ok, line_end} <- optional_line(finding, "line_end", index),
         {:ok, {line_start, line_end}} <- normalize_lines(line_start, line_end, index) do
      {:ok,
       %{
         position: index,
         file_path: file_path,
         severity: severity,
         title: title,
         description: description,
         disposition: disposition,
         claimed_canonical_public_id: canonical_public_id,
         line_start: line_start,
         line_end: line_end
       }}
    end
  end

  defp parse_finding(_finding, index), do: {:error, "findings[#{index}] must be a JSON object"}

  defp required_string(finding, key, index) do
    case Map.get(finding, key) do
      value when is_binary(value) ->
        if String.trim(value) == "" do
          {:error, "findings[#{index}]: #{key} must not be blank"}
        else
          {:ok, value}
        end

      _other ->
        {:error, "findings[#{index}]: #{key} is required and must be a string"}
    end
  end

  defp finding_severity(finding, index) do
    case Map.get(finding, "severity") do
      severity when severity in @severities ->
        {:ok, severity}

      _other ->
        {:error, "findings[#{index}]: severity must be one of #{Enum.join(@severities, ", ")}"}
    end
  end

  defp optional_disposition(finding, index) do
    case Map.get(finding, "disposition", "new") do
      disposition when disposition in ~w(new matches_existing regression not_reproduced) ->
        {:ok, disposition}

      _other ->
        {:error,
         "findings[#{index}]: disposition must be one of new, matches_existing, regression, not_reproduced"}
    end
  end

  defp optional_canonical_public_id(finding, index) do
    case Map.get(finding, "existing_finding_id") do
      nil -> {:ok, nil}
      value when is_binary(value) -> validate_uuid(value, index)
      _other -> {:error, "findings[#{index}]: existing_finding_id must be a UUID"}
    end
  end

  defp validate_uuid(value, index) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, "findings[#{index}]: existing_finding_id must be a UUID"}
    end
  end

  defp optional_line(finding, key, index) do
    case Map.get(finding, key) do
      nil ->
        {:ok, nil}

      line when is_integer(line) and line >= 1 and line <= @max_line ->
        {:ok, line}

      _other ->
        {:error,
         "findings[#{index}]: #{key} must be a positive integer no greater than #{@max_line}"}
    end
  end

  defp normalize_lines(nil, nil, _index), do: {:ok, {nil, nil}}
  defp normalize_lines(line_start, nil, _index), do: {:ok, {line_start, line_start}}

  defp normalize_lines(nil, _line_end, index),
    do: {:error, "findings[#{index}]: line_end requires line_start"}

  defp normalize_lines(line_start, line_end, _index) when line_end >= line_start,
    do: {:ok, {line_start, line_end}}

  defp normalize_lines(_line_start, _line_end, index),
    do: {:error, "findings[#{index}]: line_end must not be before line_start"}

  defp repository_path(path, index) do
    case RepositoryPath.normalize(path) do
      {:ok, ""} ->
        {:error, "findings[#{index}]: file must not be blank"}

      {:ok, path} ->
        {:ok, path}

      {:error, :invalid_path} ->
        {:error, "findings[#{index}]: file must be a safe repository-relative path"}
    end
  end
end
