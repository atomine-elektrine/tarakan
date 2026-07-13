defmodule Tarakan.Mailer.ElektrineAdapterTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Swoosh.Email

  alias Tarakan.Mailer.ElektrineAdapter

  setup :verify_on_exit!

  test "sends the Swoosh email through Elektrine" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/ext/v1/email/messages"
      assert get_req_header(conn, "authorization") == ["Bearer test-api-key"]

      assert Req.Test.raw_body(conn) |> Jason.decode!() == %{
               "from" => "security@tarakan.lol",
               "to" => "person@example.com",
               "reply_to" => "support@tarakan.lol",
               "subject" => "Your Tarakan login link",
               "text_body" => "Sign in safely"
             }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        201,
        Jason.encode!(%{
          "data" => %{
            "delivery" => %{"message_id" => "message-123", "status" => "queued"}
          }
        })
      )
    end)

    email =
      new()
      |> from({"Tarakan Security", "security@tarakan.lol"})
      |> to("person@example.com")
      |> reply_to("support@tarakan.lol")
      |> subject("Your Tarakan login link")
      |> text_body("Sign in safely")

    assert {:ok, %{id: "message-123", status: "queued"}} =
             ElektrineAdapter.deliver(email, config())
  end

  test "returns a structured Elektrine API error without response contents" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        403,
        Jason.encode!(%{
          "error" => %{
            "code" => "unauthorized_from_address",
            "message" => "The from address is not owned by your account"
          }
        })
      )
    end)

    email =
      new()
      |> from("security@tarakan.lol")
      |> to("person@example.com")
      |> subject("Test")
      |> text_body("Sensitive body")

    assert {:error, {:elektrine_api, 403, "unauthorized_from_address"}} =
             ElektrineAdapter.deliver(email, config())
  end

  test "rejects attachments instead of silently dropping them" do
    email =
      new()
      |> from("security@tarakan.lol")
      |> to("person@example.com")
      |> attachment(Swoosh.Attachment.new({:data, "contents"}, filename: "finding.txt"))

    assert {:error, :attachments_not_supported} = ElektrineAdapter.deliver(email, config())
  end

  defp config do
    [
      api_key: "test-api-key",
      base_url: "https://elektrine.test/",
      req_options: [plug: {Req.Test, __MODULE__}]
    ]
  end

  defp verify_on_exit!(_context) do
    Req.Test.verify_on_exit!()
    :ok
  end
end
