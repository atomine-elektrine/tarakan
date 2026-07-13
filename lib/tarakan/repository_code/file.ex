defmodule Tarakan.RepositoryCode.File do
  @moduledoc "A bounded UTF-8 source file pinned to one exact commit."

  @enforce_keys [:commit_sha, :path, :blob_sha, :size, :content]
  defstruct [:commit_sha, :path, :blob_sha, :size, :content]

  @type t :: %__MODULE__{
          commit_sha: String.t(),
          path: String.t(),
          blob_sha: String.t(),
          size: non_neg_integer(),
          content: String.t()
        }
end
