defmodule TarakanWeb.Presence do
  @moduledoc """
  Tracks live observers connected to the public registry.
  """

  use Phoenix.Presence,
    otp_app: :tarakan,
    pubsub_server: Tarakan.PubSub
end
