defmodule Tarakan.RepositoryPathTest do
  use ExUnit.Case, async: true

  alias Tarakan.RepositoryPath

  test "canonicalizes safe agent path variants" do
    assert RepositoryPath.normalize("./lib/foo.ex") == {:ok, "lib/foo.ex"}
    assert RepositoryPath.normalize(".\\lib\\foo.ex") == {:ok, "lib/foo.ex"}
    assert RepositoryPath.normalize("lib//foo.ex") == {:ok, "lib/foo.ex"}
    assert RepositoryPath.normalize("lib/./foo.ex") == {:ok, "lib/foo.ex"}
  end

  test "rejects absolute paths and traversal" do
    assert RepositoryPath.normalize("/etc/passwd") == {:error, :invalid_path}
    assert RepositoryPath.normalize("/lib/foo.ex") == {:error, :invalid_path}
    assert RepositoryPath.normalize("../secret") == {:error, :invalid_path}
    assert RepositoryPath.normalize("lib/../../etc/passwd") == {:error, :invalid_path}
  end

  test "fingerprint_form lowercases after canonicalize" do
    assert RepositoryPath.fingerprint_form("./Lib/Foo.EX") == "lib/foo.ex"
  end
end
