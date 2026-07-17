defmodule Tarakan.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TarakanWeb.Telemetry,
      Tarakan.Repo,
      {Oban, Application.fetch_env!(:tarakan, Oban)},
      Tarakan.RateLimiter,
      Tarakan.Git.Concurrency,
      Tarakan.RepositoryCode.Cache,
      {Task.Supervisor, name: Tarakan.TaskSupervisor},
      {DNSCluster, query: Application.get_env(:tarakan, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Tarakan.PubSub},
      TarakanWeb.Presence,
      # Start a worker by calling: Tarakan.Worker.start_link(arg)
      # {Tarakan.Worker, arg},
      # Start to serve requests, typically the last entry
      TarakanWeb.Endpoint,
      # Git-over-SSH daemon; no-op unless Tarakan.GitSSH is enabled.
      Tarakan.GitSSH.Server
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Tarakan.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TarakanWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
