defmodule Tarakan.HostedRepositories.Storage do
  @moduledoc """
  On-disk bare repositories for Tarakan-hosted projects.

  Directories are keyed by the immutable repository id, so account handle
  changes and repository renames never orphan or re-point storage; deleting
  the record deletes the directory. Repositories are created bare with
  fsck-on-transfer, a hard push size cap, and hooks disabled - hosted code is
  stored and served, never executed.
  """

  alias Tarakan.Git.Local
  alias Tarakan.Repositories.Repository

  @default_max_push_bytes 250 * 1_024 * 1_024

  def dir(%Repository{id: id}) when is_integer(id) do
    Path.join(root!(), "#{id}.git")
  end

  def exists?(%Repository{} = repository) do
    File.dir?(dir(repository))
  end

  @doc "Creates and hardens the bare repository for a fresh record."
  def init_bare(%Repository{} = repository) do
    dir = dir(repository)

    with :ok <- File.mkdir_p(dir),
         {:ok, _} <- Local.run(dir, ["init", "--bare", "--quiet", "."]),
         :ok <- harden(dir) do
      :ok
    else
      _error ->
        File.rm_rf(dir)
        {:error, :storage_init_failed}
    end
  end

  @doc "Removes a repository's storage entirely."
  def destroy(%Repository{} = repository) do
    File.rm_rf(dir(repository))
    :ok
  end

  @doc "Bytes on disk according to `git count-objects`, loose and packed."
  def disk_size_bytes(%Repository{} = repository) do
    case Local.run(dir(repository), ["count-objects", "-v"]) do
      {:ok, output} -> {:ok, parse_count_objects(output)}
      _error -> {:error, :unavailable}
    end
  end

  def max_push_bytes do
    config(:max_push_bytes, @default_max_push_bytes)
  end

  def quota_bytes do
    config(:quota_bytes, 4 * @default_max_push_bytes)
  end

  # The hardening is written into the repository's own config file so it
  # holds even when a future caller forgets the environment overrides.
  defp harden(dir) do
    [
      {"receive.fsckObjects", "true"},
      {"transfer.fsckObjects", "true"},
      {"receive.maxInputSize", "#{max_push_bytes()}"},
      {"core.hooksPath", "/dev/null"},
      {"gc.auto", "0"},
      {"uploadpack.allowFilter", "true"}
    ]
    |> Enum.reduce_while(:ok, fn {key, value}, :ok ->
      case Local.run(dir, ["config", key, value]) do
        {:ok, _output} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp parse_count_objects(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(0, fn line, total ->
      case String.split(line, ": ", parts: 2) do
        [key, kib] when key in ["size", "size-pack"] ->
          case Integer.parse(kib) do
            {kib, ""} -> total + kib * 1_024
            _other -> total
          end

        _other ->
          total
      end
    end)
  end

  defp root! do
    :tarakan
    |> Application.fetch_env!(Tarakan.HostedRepositories)
    |> Keyword.fetch!(:root)
  end

  defp config(key, default) do
    :tarakan
    |> Application.get_env(Tarakan.HostedRepositories, [])
    |> Keyword.get(key, default)
  end
end
