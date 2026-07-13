defmodule Tarakan.Accounts.AccountNotifier do
  import Swoosh.Email

  alias Tarakan.Mailer

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({"Tarakan Security", "security@tarakan.lol"})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a account email.
  """
  def deliver_update_email_instructions(account, url) do
    deliver(account.email, "Confirm your Tarakan email change", """

    ==============================

    Tarakan account @#{account.handle},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(account, url) do
    deliver_magic_link_instructions(account, url)
  end

  defp deliver_magic_link_instructions(account, url) do
    deliver(account.email, "Your Tarakan login link", """

    ==============================

    Tarakan account @#{account.handle},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end
end
