defmodule Tarakan.Repo do
  use Ecto.Repo,
    otp_app: :tarakan,
    adapter: Ecto.Adapters.Postgres
end
