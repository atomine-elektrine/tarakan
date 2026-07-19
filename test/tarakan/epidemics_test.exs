defmodule Tarakan.EpidemicsTest do
  use Tarakan.DataCase, async: true

  alias Tarakan.Epidemics
  alias Tarakan.FindingMemory

  test "pattern_key is stable and path-independent" do
    a = FindingMemory.pattern_key(%{title: "SQL injection via string concat"})
    b = FindingMemory.pattern_key(%{title: "  SQL   injection via string concat "})
    c = FindingMemory.pattern_key(%{title: "Verified: SQL injection via string concat"})

    assert a == b
    assert a == c
    assert a != FindingMemory.pattern_key(%{title: "XSS in template"})
  end

  test "lists epidemics when the same pattern hits two listed repos" do
    submitter = github_account_fixture()
    other = github_account_fixture()
    repo_a = listed_github_repository_fixture(submitter)

    {:ok, repo_b} = Tarakan.Repositories.register_github_repository("acme/widget", other)
    repo_b = listed_repository_fixture(repo_b)

    title = "Cross-repo epidemic sample #{System.unique_integer([:positive])}"

    findings = fn path ->
      Jason.encode!(%{
        "tarakan_scan_format" => 1,
        "findings" => [
          %{
            "file" => path,
            "line_start" => 1,
            "line_end" => 2,
            "severity" => "high",
            "title" => title,
            "description" => "Shared issue class for epidemic tests."
          }
        ]
      })
    end

    scan_fixture(repo_a, submitter, %{"findings_json" => findings.("lib/a.ex")})
    scan_fixture(repo_b, other, %{"findings_json" => findings.("src/b.rs")})

    pattern = FindingMemory.pattern_key(title)
    epidemics = Epidemics.list_epidemics(min_repos: 2, days: 30, limit: 50)

    assert Enum.any?(epidemics, &(&1.pattern_key == pattern and &1.repo_count >= 2))

    epidemic = Epidemics.get_epidemic(pattern)
    assert epidemic.repo_count >= 2
    assert epidemic.title =~ "Cross-repo epidemic sample"

    instances = Epidemics.list_instances(pattern)
    assert length(instances) >= 2
    assert Enum.any?(instances, &(&1.owner == "openai"))
    assert Enum.any?(instances, &(&1.owner == "acme"))
  end
end
