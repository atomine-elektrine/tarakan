defmodule TarakanWeb.FindingPresentationTest do
  use ExUnit.Case, async: true

  alias TarakanWeb.FindingPresentation

  test "structure_description splits remediation and strips Verified prefix" do
    text =
      "Verified: static HTML is served with bad CSP. That is same-origin. Remediation: force subdomains."

    %{lead: lead, sections: sections} = FindingPresentation.structure_description(text)

    assert lead =~ "static HTML"
    refute lead =~ ~r/^Verified/
    assert {"Remediation", fix} = List.keyfind(sections, "Remediation", 0)
    assert fix =~ "subdomains"
  end

  test "description_excerpt truncates lead" do
    long = String.duplicate("word ", 100)
    excerpt = FindingPresentation.description_excerpt(long, 40)
    assert String.length(excerpt) <= 41
    assert String.ends_with?(excerpt, "…")
  end

  test "humanize_notes parses auto summary" do
    notes =
      "Review Format submission with 18 finding(s). Top issues: [high] Static HTML; [medium] DNS rebinding"

    assert %{kind: :summary, count: 18, tops: tops} = FindingPresentation.humanize_notes(notes)
    assert "Static HTML" in tops
    assert Enum.any?(tops, &String.contains?(&1, "DNS"))
  end

  test "how_made_label" do
    assert FindingPresentation.how_made_label("agent") == "Produced by an agent"
    assert FindingPresentation.how_made_label("hybrid") == "Agent draft, human edited"
  end
end
