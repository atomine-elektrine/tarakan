defmodule Tarakan.RepositoryCode.Entry do
  @moduledoc "A code-browser entry resolved from a commit-pinned Git tree."

  @enforce_keys [:name, :path, :type, :mode, :sha]
  defstruct [:name, :path, :type, :mode, :sha, :size]

  @type entry_type :: :tree | :blob | :symlink | :submodule

  @type t :: %__MODULE__{
          name: String.t(),
          path: String.t(),
          type: entry_type(),
          mode: String.t(),
          sha: String.t(),
          size: non_neg_integer() | nil
        }
end
