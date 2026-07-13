defmodule Tarakan.GitHub.HTTPClientTest do
  use ExUnit.Case, async: true

  alias Tarakan.GitHub.HTTPClient

  test "accepts only explicitly public repository metadata" do
    public = %{
      "id" => 42,
      "private" => false,
      "visibility" => "public",
      "owner" => %{"login" => "openai"},
      "name" => "codex",
      "html_url" => "https://github.com/openai/codex",
      "default_branch" => "main"
    }

    assert {:ok, %{github_id: 42, owner: "openai", name: "codex"}} =
             HTTPClient.repository_metadata(public)

    assert {:error, :not_public} =
             HTTPClient.repository_metadata(%{public | "private" => true})

    assert {:error, :not_public} =
             HTTPClient.repository_metadata(%{public | "visibility" => "internal"})

    assert {:error, :not_public} =
             HTTPClient.repository_metadata(Map.delete(public, "visibility"))
  end

  test "parses commit metadata only with exact commit and root tree SHAs" do
    body = %{
      "sha" => String.duplicate("a", 40),
      "tree" => %{"sha" => String.duplicate("b", 40)},
      "committer" => %{"date" => "2026-07-10T12:00:00Z"}
    }

    assert {:ok,
            %{
              sha: unquote_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              tree_sha: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
              committed_at: ~U[2026-07-10 12:00:00Z]
            }} = HTTPClient.commit_metadata(body)

    assert unquote_sha == body["sha"]

    assert {:error, :invalid_response} =
             HTTPClient.commit_metadata(put_in(body, ["tree", "sha"], "main"))
  end

  test "extracts a branch head without requiring the heavyweight commit-diff response" do
    sha = String.duplicate("c", 40)
    tree_sha = String.duplicate("d", 40)

    body = %{
      "name" => "main",
      "commit" => %{
        "sha" => sha,
        "commit" => %{
          "tree" => %{"sha" => tree_sha},
          "committer" => %{"date" => "2026-07-10T12:00:00Z"}
        }
      }
    }

    assert {:ok, %{sha: ^sha, tree_sha: ^tree_sha, committed_at: ~U[2026-07-10 12:00:00Z]}} =
             HTTPClient.branch_metadata(body)
  end

  test "models recursive tree truncation and validates Git object modes" do
    body = %{
      "sha" => String.duplicate("1", 40),
      "truncated" => true,
      "tree" => [
        %{
          "path" => "lib",
          "mode" => "040000",
          "type" => "tree",
          "sha" => String.duplicate("2", 40)
        },
        %{
          "path" => "lib/code.ex",
          "mode" => "100644",
          "type" => "blob",
          "sha" => String.duplicate("3", 40),
          "size" => 12
        }
      ]
    }

    assert {:ok, %{truncated: true, entries: [directory, file]}} =
             HTTPClient.tree_metadata(body)

    assert directory.type == "tree"
    assert file.type == "blob"

    assert {:error, :invalid_response} =
             body
             |> put_in(["tree", Access.at(1), "mode"], "040000")
             |> HTTPClient.tree_metadata()
  end

  test "caps tree entry counts" do
    entries =
      for index <- 1..2_001 do
        %{
          "path" => "file-#{index}",
          "mode" => "100644",
          "type" => "blob",
          "sha" => String.duplicate("a", 40),
          "size" => 1
        }
      end

    assert {:error, :tree_too_large} =
             HTTPClient.tree_metadata(%{
               "sha" => String.duplicate("b", 40),
               "truncated" => false,
               "tree" => entries
             })
  end

  test "decodes bounded UTF-8 blobs and rejects binary or excessive content" do
    sha = String.duplicate("c", 40)
    content = "defmodule Safe, do: nil\n"

    assert {:ok, %{sha: ^sha, size: size, content: ^content}} =
             HTTPClient.blob_metadata(%{
               "sha" => sha,
               "size" => byte_size(content),
               "encoding" => "base64",
               "content" => Base.encode64(content)
             })

    assert size == byte_size(content)

    assert {:error, :binary_blob} =
             HTTPClient.blob_metadata(%{
               "sha" => sha,
               "size" => 3,
               "encoding" => "base64",
               "content" => Base.encode64(<<0, 1, 2>>)
             })

    assert {:error, :blob_too_large} =
             HTTPClient.blob_metadata(%{
               "sha" => sha,
               "size" => 512 * 1_024 + 1,
               "encoding" => "base64",
               "content" => ""
             })

    too_many_lines = String.duplicate("\n", 10_000)

    assert {:error, :blob_too_large} =
             HTTPClient.blob_metadata(%{
               "sha" => sha,
               "size" => byte_size(too_many_lines),
               "encoding" => "base64",
               "content" => Base.encode64(too_many_lines)
             })
  end

  test "rejects invalid object references before making an HTTP request" do
    assert {:error, :invalid_reference} =
             HTTPClient.fetch_tree("openai", "codex", "main", false)

    assert {:error, :invalid_reference} =
             HTTPClient.fetch_text_blob("../private", "codex", String.duplicate("a", 40))
  end
end
