defmodule Tarakan.GitHubStub do
  @moduledoc false

  @behaviour Tarakan.GitHubClient

  @root_tree_sha String.duplicate("1", 40)
  @lib_tree_sha String.duplicate("2", 40)
  @readme_blob_sha String.duplicate("3", 40)
  @source_blob_sha String.duplicate("4", 40)
  @large_blob_sha String.duplicate("5", 40)
  @binary_blob_sha String.duplicate("6", 40)
  @default_commit_sha String.duplicate("7", 40)
  @symlink_blob_sha String.duplicate("9", 40)
  @submodule_sha String.duplicate("a", 40)
  @many_lines_blob_sha String.duplicate("d", 40)
  @truncated_tree_sha String.duplicate("e", 40)
  @unsafe_html_blob_sha String.duplicate("f", 40)
  @readme "# Codex\n"
  @source "defmodule Codex do\n  def hello, do: :world\nend\n"
  @unsafe_html "</code><script id=\"source-xss\">alert(1)</script>\n"

  @codex_etag ~s(W/"codex-metadata")

  def codex_etag, do: @codex_etag

  @impl true
  def fetch_repository(owner, name, opts \\ [])

  def fetch_repository("openai", "codex", opts) do
    if Keyword.get(opts, :etag) == @codex_etag do
      :not_modified
    else
      {:ok,
       %{
         github_id: 95_959_834,
         node_id: "R_kgDOcodex000",
         host: "github.com",
         owner: "openai",
         name: "codex",
         canonical_url: "https://github.com/openai/codex",
         default_branch: "main",
         description: "Lightweight coding agent that runs in your terminal",
         primary_language: "Rust",
         stars_count: 42_000,
         forks_count: 4_200,
         archived: false,
         private: false,
         visibility: "public",
         last_synced_at: ~U[2026-07-10 04:00:00.000000Z],
         etag: @codex_etag
       }}
    end
  end

  def fetch_repository("missing", "repository", _opts), do: {:error, :not_found}

  # Renamed on the host: the old path 301s, the immutable id resolves to acme/widget.
  def fetch_repository("legacy", "widget", _opts), do: {:error, :moved}

  def fetch_repository("acme", "widget", _opts), do: {:ok, renamed_widget_metadata()}

  def fetch_repository("private", "repository", _opts) do
    {:ok,
     %{
       github_id: 12_345,
       host: "github.com",
       owner: "private",
       name: "repository",
       canonical_url: "https://github.com/private/repository",
       default_branch: "main",
       private: true,
       visibility: "private"
     }}
  end

  def fetch_repository("rate", "limited", _opts), do: {:error, :rate_limited}

  def fetch_repository("flip", "repository", _opts) do
    count = Process.get(:github_flip_identity_count, 0)
    Process.put(:github_flip_identity_count, count + 1)

    if count == 0 do
      {:ok,
       %{
         github_id: 88_888,
         host: "github.com",
         owner: "flip",
         name: "repository",
         canonical_url: "https://github.com/flip/repository",
         default_branch: "main",
         private: false,
         visibility: "public"
       }}
    else
      {:ok,
       %{
         github_id: 88_888,
         owner: "flip",
         name: "repository",
         default_branch: "main",
         private: true,
         visibility: "private"
       }}
    end
  end

  def fetch_repository("lateflip", "repository", _opts) do
    count = Process.get(:github_late_flip_identity_count, 0)
    Process.put(:github_late_flip_identity_count, count + 1)

    if count < 3 do
      {:ok,
       %{
         github_id: 99_999,
         host: "github.com",
         owner: "lateflip",
         name: "repository",
         canonical_url: "https://github.com/lateflip/repository",
         default_branch: "main",
         private: false,
         visibility: "public"
       }}
    else
      {:ok,
       %{
         github_id: 99_999,
         owner: "lateflip",
         name: "repository",
         default_branch: "main",
         private: true,
         visibility: "private"
       }}
    end
  end

  def fetch_repository(_owner, _name, _opts), do: {:error, :unavailable}

  @impl true
  def fetch_repository_by_id(95_959_834), do: fetch_repository("openai", "codex", [])
  def fetch_repository_by_id(12_345), do: fetch_repository("private", "repository", [])
  def fetch_repository_by_id(88_888), do: fetch_repository("flip", "repository", [])
  def fetch_repository_by_id(99_999), do: fetch_repository("lateflip", "repository", [])
  def fetch_repository_by_id(77_777), do: {:ok, renamed_widget_metadata()}
  def fetch_repository_by_id(_github_id), do: {:error, :not_found}

  defp renamed_widget_metadata do
    %{
      github_id: 77_777,
      node_id: "R_kgDOwidget00",
      host: "github.com",
      owner: "acme",
      name: "widget",
      canonical_url: "https://github.com/acme/widget",
      default_branch: "main",
      description: "Widget toolkit",
      primary_language: "Elixir",
      stars_count: 12,
      forks_count: 3,
      archived: false,
      private: false,
      visibility: "public",
      last_synced_at: ~U[2026-07-10 04:00:00.000000Z]
    }
  end

  @impl true
  def fetch_commit("openai", "codex", "dead" <> _rest), do: {:error, :not_found}

  def fetch_commit("openai", "codex", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") do
    {:ok,
     %{
       sha: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
       tree_sha: @root_tree_sha,
       committed_at: ~U[2026-07-01 12:00:00Z]
     }}
  end

  def fetch_commit("openai", "codex", "cccccccccccccccccccccccccccccccccccccccc") do
    {:ok,
     %{
       sha: "cccccccccccccccccccccccccccccccccccccccc",
       tree_sha: @truncated_tree_sha,
       committed_at: ~U[2026-07-01 12:00:00Z]
     }}
  end

  # Second precision, mirroring what the GitHub API actually returns.
  def fetch_commit("openai", "codex", sha),
    do:
      {:ok,
       %{
         sha: String.downcase(sha),
         tree_sha: @root_tree_sha,
         committed_at: ~U[2026-07-01 12:00:00Z]
       }}

  def fetch_commit("acme", "widget", sha), do: fetch_commit("openai", "codex", sha)
  def fetch_commit("rate", "limited", _sha), do: {:error, :rate_limited}
  def fetch_commit("flip", "repository", sha), do: fetch_commit("openai", "codex", sha)
  def fetch_commit("lateflip", "repository", sha), do: fetch_commit("openai", "codex", sha)
  def fetch_commit(_owner, _name, _sha), do: {:error, :unavailable}

  @impl true
  def fetch_branch_head("openai", "codex", "main") do
    {:ok,
     %{
       sha: @default_commit_sha,
       tree_sha: @root_tree_sha,
       committed_at: ~U[2026-07-01 12:00:00Z]
     }}
  end

  def fetch_branch_head("openai", "codex", "develop") do
    {:ok,
     %{
       sha: String.duplicate("8", 40),
       tree_sha: @root_tree_sha,
       committed_at: ~U[2026-07-02 12:00:00Z]
     }}
  end

  def fetch_branch_head("acme", "widget", branch),
    do: fetch_branch_head("openai", "codex", branch)

  def fetch_branch_head("rate", "limited", _branch), do: {:error, :rate_limited}
  def fetch_branch_head(_owner, _name, _branch), do: {:error, :not_found}

  @impl true
  def list_branches("openai", "codex"), do: {:ok, ["main", "develop", "feature/auth"]}
  def list_branches("acme", "widget"), do: list_branches("openai", "codex")
  def list_branches("rate", "limited"), do: {:error, :rate_limited}
  def list_branches(_owner, _name), do: {:error, :not_found}

  @impl true
  def fetch_tree("openai", "codex", @root_tree_sha, recursive) do
    direct_entries = [
      %{path: "lib", mode: "040000", type: "tree", sha: @lib_tree_sha, size: nil},
      %{
        path: "README.md",
        mode: "100644",
        type: "blob",
        sha: @readme_blob_sha,
        size: byte_size(@readme)
      },
      %{
        path: "space # 100%.txt",
        mode: "100644",
        type: "blob",
        sha: @readme_blob_sha,
        size: byte_size(@readme)
      },
      %{
        path: "λ.ex",
        mode: "100644",
        type: "blob",
        sha: @source_blob_sha,
        size: byte_size(@source)
      },
      %{
        path: "large.txt",
        mode: "100644",
        type: "blob",
        sha: @large_blob_sha,
        size: 512 * 1_024 + 1
      },
      %{
        path: "binary.dat",
        mode: "100644",
        type: "blob",
        sha: @binary_blob_sha,
        size: 4
      },
      %{
        path: "many-lines.txt",
        mode: "100644",
        type: "blob",
        sha: @many_lines_blob_sha,
        size: 10_000
      },
      %{
        path: "unsafe.html",
        mode: "100644",
        type: "blob",
        sha: @unsafe_html_blob_sha,
        size: byte_size(@unsafe_html)
      },
      %{
        path: "source-link",
        mode: "120000",
        type: "symlink",
        sha: @symlink_blob_sha,
        size: 12
      },
      %{
        path: "dependency",
        mode: "160000",
        type: "submodule",
        sha: @submodule_sha,
        size: nil
      }
    ]

    entries =
      if recursive do
        direct_entries ++
          [
            %{
              path: "lib/codex.ex",
              mode: "100644",
              type: "blob",
              sha: @source_blob_sha,
              size: byte_size(@source)
            }
          ]
      else
        direct_entries
      end

    {:ok, %{sha: @root_tree_sha, truncated: false, entries: entries}}
  end

  def fetch_tree("openai", "codex", @lib_tree_sha, _recursive) do
    {:ok,
     %{
       sha: @lib_tree_sha,
       truncated: false,
       entries: [
         %{
           path: "codex.ex",
           mode: "100644",
           type: "blob",
           sha: @source_blob_sha,
           size: byte_size(@source)
         }
       ]
     }}
  end

  def fetch_tree("openai", "codex", @truncated_tree_sha, _recursive) do
    {:ok, %{sha: @truncated_tree_sha, truncated: true, entries: []}}
  end

  def fetch_tree("acme", "widget", tree_sha, recursive),
    do: fetch_tree("openai", "codex", tree_sha, recursive)

  def fetch_tree("rate", "limited", _tree_sha, _recursive), do: {:error, :rate_limited}

  def fetch_tree("flip", "repository", tree_sha, recursive),
    do: fetch_tree("openai", "codex", tree_sha, recursive)

  def fetch_tree("lateflip", "repository", tree_sha, recursive),
    do: fetch_tree("openai", "codex", tree_sha, recursive)

  def fetch_tree(_owner, _name, _tree_sha, _recursive), do: {:error, :not_found}

  @impl true
  def fetch_text_blob("openai", "codex", @readme_blob_sha) do
    {:ok, %{sha: @readme_blob_sha, size: byte_size(@readme), content: @readme}}
  end

  def fetch_text_blob("openai", "codex", @source_blob_sha) do
    {:ok, %{sha: @source_blob_sha, size: byte_size(@source), content: @source}}
  end

  def fetch_text_blob("openai", "codex", @binary_blob_sha) do
    {:ok, %{sha: @binary_blob_sha, size: 4, content: <<0, 1, 2, 3>>}}
  end

  def fetch_text_blob("openai", "codex", @many_lines_blob_sha) do
    content = String.duplicate("\n", 10_000)
    {:ok, %{sha: @many_lines_blob_sha, size: byte_size(content), content: content}}
  end

  def fetch_text_blob("openai", "codex", @unsafe_html_blob_sha) do
    {:ok,
     %{
       sha: @unsafe_html_blob_sha,
       size: byte_size(@unsafe_html),
       content: @unsafe_html
     }}
  end

  def fetch_text_blob("openai", "codex", @large_blob_sha), do: {:error, :unavailable}

  def fetch_text_blob("acme", "widget", blob_sha),
    do: fetch_text_blob("openai", "codex", blob_sha)

  def fetch_text_blob("rate", "limited", _blob_sha), do: {:error, :rate_limited}
  def fetch_text_blob(_owner, _name, _blob_sha), do: {:error, :not_found}
end

defmodule Tarakan.GitHub.OAuthStub do
  @moduledoc false

  @behaviour Tarakan.GitHub.OAuthClient

  @impl true
  def exchange_code("valid-code", verifier, redirect_uri)
      when is_binary(verifier) and is_binary(redirect_uri),
      do: {:ok, "temporary-user-token"}

  def exchange_code(_code, _verifier, _redirect_uri), do: {:error, :authorization_failed}

  @impl true
  def fetch_user("temporary-user-token") do
    {:ok,
     %{
       provider_uid: 58_399_067,
       provider_login: "TarakanTester",
       name: "Tarakan Tester",
       avatar_url: "https://avatars.githubusercontent.com/u/58399067",
       profile_url: "https://github.com/TarakanTester"
     }}
  end

  def fetch_user(_token), do: {:error, :authorization_failed}
end
