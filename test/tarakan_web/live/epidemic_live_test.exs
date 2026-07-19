defmodule TarakanWeb.EpidemicLiveTest do
  use TarakanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tarakan.FindingMemory

  test "index and show render multi-repo patterns", %{conn: conn} do
    submitter = github_account_fixture()
    other = github_account_fixture()
    repo_a = listed_github_repository_fixture(submitter)
    {:ok, repo_b} = Tarakan.Repositories.register_github_repository("acme/widget", other)
    repo_b = listed_repository_fixture(repo_b)

    title = "Live epidemic #{System.unique_integer([:positive])}"

    findings = fn path ->
      Jason.encode!(%{
        "tarakan_scan_format" => 1,
        "findings" => [
          %{
            "file" => path,
            "severity" => "critical",
            "title" => title,
            "description" => "Epidemic liveview fixture."
          }
        ]
      })
    end

    scan_fixture(repo_a, submitter, %{"findings_json" => findings.("a.ex")})
    scan_fixture(repo_b, other, %{"findings_json" => findings.("b.ex")})

    pattern = FindingMemory.pattern_key(title)

    {:ok, index, html} = live(conn, ~p"/patterns")
    assert html =~ "Patterns"
    assert has_element?(index, "#epidemics-constellation")
    assert has_element?(index, "#epidemic-#{pattern}")

    {:ok, show, show_html} = live(conn, ~p"/patterns/#{pattern}")
    assert show_html =~ title
    assert has_element?(show, "#epidemic-repo-count", "2")
    assert has_element?(show, "#epidemic-contagion")
    assert has_element?(show, "#epidemic-instances")
  end
end
