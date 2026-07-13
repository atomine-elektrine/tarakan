defmodule Tarakan.RepositoryCode.Tree do
  @moduledoc "A directory listing pinned to one exact commit."

  alias Tarakan.RepositoryCode.Entry

  @enforce_keys [:commit_sha, :path, :tree_sha, :entries, :truncated]
  defstruct [:commit_sha, :path, :tree_sha, :entries, :truncated]

  @type t :: %__MODULE__{
          commit_sha: String.t(),
          path: String.t(),
          tree_sha: String.t(),
          entries: [Entry.t()],
          truncated: boolean()
        }
end
