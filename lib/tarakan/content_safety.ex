defmodule Tarakan.ContentSafety do
  @moduledoc """
  Lightweight publish-time checks for secrets and credential-shaped payloads.

  Rejects high-confidence secret patterns so the public record cannot be used
  as a pastebin for keys. False positives are possible; callers surface a
  generic error and ask reporters to redact.
  """

  @patterns [
    # PEM private keys
    ~r/-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----/,
    # AWS access key id
    ~r/(?:^|[^A-Z0-9])(?:AKIA|ASIA)[A-Z0-9]{16}(?:[^A-Z0-9]|$)/,
    # GitHub classic / fine-grained PATs
    ~r/(?:^|[^a-z0-9_])gh[pousr]_[A-Za-z0-9_]{20,}(?:[^A-Za-z0-9_]|$)/,
    ~r/(?:^|[^a-z0-9_])github_pat_[A-Za-z0-9_]{20,}(?:[^A-Za-z0-9_]|$)/,
    # Slack tokens
    ~r/xox[baprs]-[A-Za-z0-9-]{10,}/,
    # Google API keys
    ~r/(?:^|[^A-Za-z0-9])AIza[0-9A-Za-z\-_]{35}(?:[^A-Za-z0-9]|$)/,
    # Stripe live secret keys
    ~r/(?:^|[^A-Za-z0-9_])sk_live_[0-9a-zA-Z]{20,}(?:[^A-Za-z0-9_]|$)/,
    # JWT-looking triples with long segments (often leaked session tokens)
    ~r/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/,
    # Generic high-entropy assignment of secret-ish names
    ~r/(?i)(?:api[_-]?key|secret[_-]?key|access[_-]?token|private[_-]?key)\s*[:=]\s*['\"]?[A-Za-z0-9\/\+=_\-]{24,}/
  ]

  @doc """
  Scans free-text for secret-like material.

  Returns `:ok` or `{:error, :secrets_detected}`.
  """
  def scan_text(nil), do: :ok
  def scan_text(""), do: :ok

  def scan_text(text) when is_binary(text) do
    if Enum.any?(@patterns, &Regex.match?(&1, text)) do
      {:error, :secrets_detected}
    else
      :ok
    end
  end

  def scan_text(_), do: :ok

  @doc "Scans a list of finding attribute maps (title + description)."
  def scan_findings(findings) when is_list(findings) do
    Enum.reduce_while(findings, :ok, fn finding, :ok ->
      text =
        [
          Map.get(finding, :title) || Map.get(finding, "title"),
          Map.get(finding, :description) || Map.get(finding, "description")
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      case scan_text(text) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def scan_findings(_), do: :ok

  @doc "Scans report-level notes plus findings from a submission attrs map."
  def scan_submission(attrs) when is_map(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    with :ok <- scan_text(attrs["notes"]),
         :ok <- scan_text(attrs["findings_json"] || attrs["raw_document"]) do
      :ok
    end
  end

  def scan_submission(_), do: :ok
end
