defmodule TarakanWeb.EpidemicComponents do
  @moduledoc """
  Functional epidemic surfaces: ranked pattern table and per-pattern repo matrix.
  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: TarakanWeb.Endpoint,
    router: TarakanWeb.Router,
    statics: TarakanWeb.static_paths()

  attr :epidemics, :list, required: true
  attr :id, :string, default: "epidemic-constellation"
  attr :compact, :boolean, default: false

  @doc "Ranked multi-repo patterns (homepage / index)."
  def constellation(assigns) do
    max_repos =
      assigns.epidemics
      |> Enum.map(& &1.repo_count)
      |> Enum.max(fn -> 1 end)

    assigns = assign(assigns, :max_repos, max(max_repos, 1))

    ~H"""
    <div id={@id} class="border-2 border-strong bg-ground">
      <div class="overflow-x-auto">
        <table class="w-full min-w-[36rem] border-collapse text-left">
          <thead>
            <tr class="border-b border-rule font-mono text-[10px] uppercase tracking-[0.14em] text-ink-faint">
              <th class="w-10 px-3 py-2 font-normal sm:px-4">#</th>
              <th class="px-2 py-2 font-normal">Pattern</th>
              <th class="w-[7rem] px-2 py-2 font-normal sm:w-[10rem]">Spread</th>
              <th class="w-16 px-2 py-2 text-right font-normal tabular-nums">Repos</th>
              <th class="hidden w-14 px-2 py-2 text-right font-normal sm:table-cell">Open</th>
              <th class="hidden w-14 px-2 py-2 text-right font-normal md:table-cell">Ver</th>
              <th class="hidden w-14 px-2 py-2 text-right font-normal md:table-cell">Fix</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-rule">
            <tr
              :for={{epidemic, i} <- Enum.with_index(@epidemics, 1)}
              class="group transition-colors hover:bg-panel"
            >
              <td class="px-3 py-2.5 font-mono text-[11px] tabular-nums text-ink-faint sm:px-4">
                {i}
              </td>
              <td class="min-w-0 px-2 py-2.5">
                <.link
                  id={"#{@id}-hub-#{epidemic.pattern_key}"}
                  navigate={~p"/patterns/#{epidemic.pattern_key}"}
                  class="block min-w-0"
                >
                  <span class="flex flex-wrap items-center gap-2">
                    <span
                      :if={epidemic.severity}
                      class="shrink-0 font-mono text-[9px] uppercase tracking-[0.12em] text-signal"
                    >
                      {epidemic.severity}
                    </span>
                    <span class="truncate text-sm font-semibold text-ink group-hover:text-signal">
                      {epidemic.title}
                    </span>
                  </span>
                  <span
                    :if={!@compact}
                    class="mt-0.5 block truncate font-mono text-[10px] text-ink-faint"
                  >
                    {String.slice(epidemic.pattern_key, 0, 12)}…
                  </span>
                </.link>
              </td>
              <td class="px-2 py-2.5">
                <div class="flex items-center gap-2">
                  <div class="h-1.5 min-w-0 flex-1 bg-rule">
                    <div
                      class="h-full bg-signal"
                      style={"width: #{bar_pct(epidemic.repo_count, @max_repos)}%"}
                    >
                    </div>
                  </div>
                </div>
              </td>
              <td class="px-2 py-2.5 text-right font-display text-lg tabular-nums text-ink">
                {epidemic.repo_count}
              </td>
              <td class="hidden px-2 py-2.5 text-right font-mono text-xs tabular-nums text-phosphor sm:table-cell">
                {epidemic.open_count}
              </td>
              <td class="hidden px-2 py-2.5 text-right font-mono text-xs tabular-nums text-ink md:table-cell">
                {epidemic.verified_count}
              </td>
              <td class="hidden px-2 py-2.5 text-right font-mono text-xs tabular-nums text-ink-muted md:table-cell">
                {epidemic.fixed_count}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :instances, :list, required: true
  attr :epidemic, :map, required: true
  attr :pattern_key, :string, required: true
  attr :id, :string, default: "epidemic-graph"

  @doc "Per-repo infection matrix for one pattern."
  def contagion_graph(assigns) do
    ~H"""
    <div id={@id} class="border-2 border-strong bg-ground">
      <div
        :if={@instances == []}
        class="px-4 py-10 text-center font-mono text-xs text-ink-faint"
      >
        No listed public instances.
      </div>

      <div :if={@instances != []} class="overflow-x-auto">
        <table class="w-full min-w-[32rem] border-collapse text-left">
          <thead>
            <tr class="border-b border-rule font-mono text-[10px] uppercase tracking-[0.14em] text-ink-faint">
              <th class="w-8 px-3 py-2 font-normal sm:px-4"></th>
              <th class="px-2 py-2 font-normal">Repository</th>
              <th class="w-24 px-2 py-2 font-normal">Status</th>
              <th class="hidden px-2 py-2 font-normal sm:table-cell">Sample</th>
              <th class="w-20 px-3 py-2 text-right font-normal sm:px-4"></th>
            </tr>
          </thead>
          <tbody class="divide-y divide-rule">
            <tr
              :for={inst <- @instances}
              id={"#{@id}-node-#{inst.id}"}
              class="group transition-colors hover:bg-panel"
            >
              <td class="px-3 py-2.5 sm:px-4">
                <span class={[
                  "inline-block size-2 rounded-full",
                  inst.status == "open" && "bg-phosphor",
                  inst.status == "verified" && "bg-ink",
                  inst.status == "fixed" && "bg-ink-muted",
                  inst.status not in ["open", "verified", "fixed"] && "bg-ink-faint"
                ]}></span>
              </td>
              <td class="min-w-0 px-2 py-2.5">
                <span class="block truncate font-mono text-xs font-semibold text-ink">
                  {inst.owner}/{inst.name}
                </span>
              </td>
              <td class="px-2 py-2.5">
                <span class={[
                  "font-mono text-[10px] uppercase tracking-[0.12em]",
                  inst.status == "open" && "text-phosphor",
                  inst.status == "verified" && "text-ink",
                  inst.status == "fixed" && "text-ink-muted",
                  inst.status not in ["open", "verified", "fixed"] && "text-ink-faint"
                ]}>
                  {inst.status}
                </span>
              </td>
              <td class="hidden min-w-0 px-2 py-2.5 sm:table-cell">
                <span class="block truncate font-mono text-[11px] text-ink-faint">
                  {inst[:file_path] || "—"}
                </span>
              </td>
              <td class="px-3 py-2.5 text-right sm:px-4">
                <.link
                  :if={inst.occurrence_public_id}
                  navigate={~p"/findings/#{inst.occurrence_public_id}"}
                  class="font-mono text-[11px] text-signal hover:underline"
                >
                  Finding →
                </.link>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp bar_pct(count, max) when max > 0 do
    count
    |> Kernel./(max)
    |> Kernel.*(100)
    |> Float.round(1)
    |> max(4)
    |> min(100)
  end

  defp bar_pct(_, _), do: 0
end
