defmodule Tarakan.Moderation.Holds do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Tarakan.Moderation.Case, as: ModerationCase
  alias Tarakan.Repo
  alias Tarakan.Scans.Finding

  @active_status "resolved"

  @doc "Whether an upheld repository moderation decision still requires containment."
  def repository_held?(repository_id) when is_integer(repository_id) do
    held?("repository", repository_id)
  end

  def repository_held?(_repository_id), do: false

  @doc "Whether an upheld scan or one of its findings still requires containment."
  def scan_held?(scan_id) when is_integer(scan_id) do
    held?("scan", scan_id) or finding_held?(scan_id)
  end

  def scan_held?(_scan_id), do: false

  defp held?(subject_type, subject_id) do
    Repo.exists?(
      from case_record in ModerationCase,
        where:
          case_record.subject_type == ^subject_type and
            case_record.subject_id == ^subject_id and
            case_record.status == @active_status
    )
  end

  defp finding_held?(scan_id) do
    Repo.exists?(
      from case_record in ModerationCase,
        join: finding in Finding,
        on:
          case_record.subject_type == "finding" and
            case_record.subject_id == finding.id,
        where: finding.scan_id == ^scan_id and case_record.status == @active_status
    )
  end
end
