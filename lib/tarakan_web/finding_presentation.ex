defmodule TarakanWeb.FindingPresentation do
  @moduledoc """
  Presentation helpers for scan findings and review records.

  Agents often dump evidence + remediation into one description paragraph.
  We split common labels so the UI can show readable sections without changing
  the wire format.
  """

  @section_labels ~w(Remediation Fix Impact Evidence Why Problem Summary Context)

  @doc """
  Break a free-form finding description into `{lead, sections}` for display.

  Recognizes labels like `Remediation:`, `Impact:`, `Evidence:` (case-insensitive).
  Leading noise such as `Verified:` / `Hypothesis:` is stripped from the lead.
  """
  def structure_description(nil), do: %{lead: "", sections: []}
  def structure_description(""), do: %{lead: "", sections: []}

  def structure_description(text) when is_binary(text) do
    text = String.trim(text)
    {lead, sections} = extract_sections(text)

    lead =
      lead
      |> strip_status_prefix()
      |> String.trim()

    sections =
      sections
      |> Enum.map(fn {label, body} -> {label, String.trim(body)} end)
      |> Enum.reject(fn {_label, body} -> body == "" end)

    %{lead: lead, sections: sections}
  end

  @doc "Short body for list cards - lead only, truncated."
  def description_excerpt(text, max \\ 280) do
    %{lead: lead, sections: sections} = structure_description(text)

    body =
      cond do
        lead != "" -> lead
        sections != [] -> sections |> List.first() |> elem(1)
        true -> String.trim(to_string(text || ""))
      end

    truncate_runes(body, max)
  end

  @doc "Plain-English provenance for readers, not wire jargon."
  def how_made_label("agent"), do: "Produced by an agent"
  def how_made_label("human"), do: "Written by a human"
  def how_made_label("hybrid"), do: "Agent draft, human-guided"
  def how_made_label(other) when is_binary(other), do: other
  def how_made_label(_), do: "Unknown"

  @doc "Short status label with meaning."
  def status_blurb("quarantined"),
    do: "Submitted (not accepted)"

  def status_blurb("accepted"), do: "Accepted"
  def status_blurb("rejected"), do: "Rejected"
  def status_blurb("contested"), do: "Contested"
  def status_blurb(other) when is_binary(other), do: other
  def status_blurb(_), do: ""

  @doc "Humanize auto-generated submitter notes when possible."
  def humanize_notes(nil), do: nil
  def humanize_notes(""), do: nil

  def humanize_notes(notes) when is_binary(notes) do
    trimmed = String.trim(notes)

    case Regex.run(
           ~r/^Review Format submission with (\d+) finding\(s\)\.\s*Top issues:\s*(.+)$/s,
           trimmed
         ) do
      [_, count, tops] ->
        tops =
          tops
          |> String.split(";")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(fn item ->
            item
            |> String.replace(~r/^\[([^\]]+)\]\s*/, "")
            |> String.trim()
          end)

        %{kind: :summary, count: String.to_integer(count), tops: tops}

      _ ->
        %{kind: :plain, text: trimmed}
    end
  end

  defp strip_status_prefix(text) do
    Regex.replace(
      ~r/^(Verified|Hypothesis(?:\/low)?|Hypothesis|Unverified|Likely|Possible)\s*:\s*/i,
      text,
      ""
    )
  end

  # Walk the text for "Label:" markers and peel into ordered sections.
  defp extract_sections(text) do
    labels = Enum.join(@section_labels, "|")
    # Match label at start or after whitespace/.!?\n
    re = ~r/(?:(?<=^)|(?<=[.!?\n])\s+)(#{labels})\s*:\s+/i

    case Regex.scan(re, text, return: :index) do
      [] ->
        {text, []}

      matches ->
        # matches is [[{full_start, full_len}, {label_start, label_len}], ...]
        first = hd(matches)
        [{full_start, _full_len}, {_ls, _ll}] = first
        lead = String.slice(text, 0, full_start) |> String.trim()

        sections =
          matches
          |> Enum.with_index()
          |> Enum.map(fn {[{fs, fl}, {ls, ll}], idx} ->
            label =
              text
              |> String.slice(ls, ll)
              |> String.trim()
              |> String.capitalize()

            body_start = fs + fl

            body_end =
              case Enum.at(matches, idx + 1) do
                [{next_fs, _} | _] -> next_fs
                _ -> String.length(text)
              end

            body =
              text
              |> String.slice(body_start, body_end - body_start)
              |> String.trim()

            {label, body}
          end)

        {lead, sections}
    end
  end

  defp truncate_runes(text, max) when is_binary(text) and is_integer(max) and max > 0 do
    graphemes = String.graphemes(text)

    if length(graphemes) <= max do
      text
    else
      graphemes
      |> Enum.take(max - 1)
      |> Enum.join()
      |> Kernel.<>("…")
    end
  end
end
