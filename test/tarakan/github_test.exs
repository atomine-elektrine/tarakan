defmodule Tarakan.GitHubTest do
  use ExUnit.Case, async: true

  alias Tarakan.GitHub

  test "enforces public metadata at the adapter trust boundary" do
    assert {:ok,
            %{
              github_id: 95_959_834,
              owner: "openai",
              name: "codex",
              private: false,
              visibility: "public"
            }} = GitHub.fetch_public_repository("openai", "codex")

    assert {:error, :not_public} = GitHub.fetch_public_repository("private", "repository")
  end

  test "verifies that a path still resolves to the registered repository identity" do
    assert {:ok, %{github_id: 95_959_834}} =
             GitHub.verify_public_identity(%{
               owner: "openai",
               name: "codex",
               github_id: 95_959_834
             })

    assert {:error, :identity_changed} =
             GitHub.verify_public_identity(%{
               owner: "openai",
               name: "codex",
               github_id: 1
             })

    assert {:error, :identity_changed} =
             GitHub.verify_public_identity(%{
               owner: "private",
               name: "repository",
               github_id: 12_345
             })

    assert {:error, :identity_changed} =
             GitHub.verify_public_identity(%{
               owner: "missing",
               name: "repository",
               github_id: 12_345
             })
  end
end
