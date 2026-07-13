defmodule Tarakan.Mailer.ElektrineAdapter do
  @moduledoc """
  Delivers Swoosh emails through Elektrine's scoped external email API.

  Elektrine validates that the requested sender belongs to the API token's
  account. Automatic HTTP retries are disabled because the send endpoint does
  not currently expose an idempotency key.
  """

  use Swoosh.Adapter,
    required_config: [:api_key],
    required_deps: [Req]

  alias Swoosh.Email

  @default_base_url "https://elektrine.com"
  @email_path "/api/ext/v1/email/messages"

  @impl true
  def deliver(%Email{attachments: [_attachment | _rest]}, _config) do
    {:error, :attachments_not_supported}
  end

  def deliver(%Email{} = email, config) do
    request_options =
      [
        url: endpoint(config),
        headers: [
          {"authorization", "Bearer #{config[:api_key]}"},
          {"accept", "application/json"}
        ],
        json: payload(email),
        retry: false,
        receive_timeout: Keyword.get(config, :receive_timeout, 15_000)
      ]
      |> Keyword.merge(Keyword.get(config, :req_options, []))

    case Req.post(request_options) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, delivery_metadata(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:elektrine_api, status, error_code(body)}}

      {:error, reason} ->
        {:error, {:elektrine_transport, reason}}
    end
  end

  defp endpoint(config) do
    config
    |> Keyword.get(:base_url, @default_base_url)
    |> String.trim_trailing("/")
    |> Kernel.<>(@email_path)
  end

  defp payload(email) do
    %{
      "from" => address(email.from),
      "to" => addresses(email.to),
      "cc" => addresses(email.cc),
      "bcc" => addresses(email.bcc),
      "reply_to" => addresses(List.wrap(email.reply_to)),
      "subject" => email.subject,
      "text_body" => email.text_body,
      "html_body" => email.html_body
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp addresses(recipients) do
    recipients
    |> Enum.map(&address/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp address({_name, address}) when is_binary(address), do: address
  defp address(address) when is_binary(address), do: address
  defp address(_recipient), do: nil

  defp delivery_metadata(%{"data" => data}) when is_map(data) do
    delivery = Map.get(data, "delivery", %{})

    %{
      id: Map.get(delivery, "message_id"),
      status: Map.get(delivery, "status", "sent")
    }
  end

  defp delivery_metadata(_body), do: %{id: nil, status: "sent"}

  defp error_code(%{"error" => %{"code" => code}}) when is_binary(code), do: code
  defp error_code(_body), do: "request_failed"
end
