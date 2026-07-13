defmodule TarakanWeb.Plugs.ClientIp do
  @moduledoc """
  Rewrites `conn.remote_ip` from a trusted reverse proxy's forwarded headers.

  Only applies when:

  1. `:trusted_proxies` is configured (CIDR strings or IPs), and
  2. the direct TCP peer is inside that set.

  Without trusted proxies configured, the peer address is left untouched so
  clients cannot spoof `X-Forwarded-For` against a publicly exposed app.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case trusted_proxies() do
      [] ->
        conn

      proxies ->
        if trusted_ip?(conn.remote_ip, proxies) do
          case client_ip_from_headers(forwarded_values(conn), proxies) do
            ip when is_tuple(ip) -> %{conn | remote_ip: ip}
            nil -> conn
          end
        else
          conn
        end
    end
  end

  @doc "Resolves a client IP string for rate limiting from a Plug.Conn."
  def remote_ip_string(%Plug.Conn{} = conn) do
    conn.remote_ip
    |> normalize_ip()
    |> :inet.ntoa()
    |> to_string()
  rescue
    _error -> "unavailable"
  end

  @doc false
  def trusted_ip?(ip, proxies) when is_tuple(ip) and is_list(proxies) do
    normalized = normalize_ip(ip)
    Enum.any?(proxies, &ip_in_proxy?(normalized, &1))
  end

  def trusted_ip?(_ip, _proxies), do: false

  @doc """
  Selects the real client IP from forwarded header values.

  `values` is the list of raw `X-Forwarded-For` header strings (each may itself
  be comma-separated). Proxies append the peer they received from, so the
  rightmost entry is closest to us; we walk from the right, skip every trusted
  proxy, and take the first untrusted hop. That address is the furthest one we
  can still attribute to a hop we trust — anything to its left is
  client-supplied and spoofable. Returns an IP tuple, or `nil` when nothing
  parses.
  """
  def client_ip_from_headers(values, proxies) when is_list(values) and is_list(proxies) do
    ips =
      values
      |> Enum.flat_map(&String.split(&1, ",", trim: true))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&parse_ip/1)
      |> Enum.reject(&is_nil/1)

    case ips do
      [] ->
        nil

      _ ->
        rightmost_untrusted =
          ips
          |> Enum.reverse()
          |> Enum.drop_while(&trusted_ip?(&1, proxies))
          |> List.first()

        # When every hop is a trusted proxy, the leftmost entry is the best
        # available guess at the original client.
        normalize_ip(rightmost_untrusted || List.first(ips))
    end
  end

  defp forwarded_values(conn) do
    Enum.flat_map(forwarded_headers(), &Plug.Conn.get_req_header(conn, &1))
  end

  defp parse_ip(nil), do: nil

  defp parse_ip(value) do
    value = value |> String.trim_leading("[") |> String.trim_trailing("]")

    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, ip} -> ip
      {:error, _reason} -> nil
    end
  end

  # IPv4-mapped IPv6 addresses (::ffff:a.b.c.d) arrive as 8-tuples on a
  # dual-stack (`::`) listener; fold them to the plain IPv4 tuple so trusted
  # proxy CIDRs match and rate-limit keys stay stable across families.
  defp normalize_ip({0, 0, 0, 0, 0, 0xFFFF, g, h}) do
    {Bitwise.bsr(g, 8), Bitwise.band(g, 0xFF), Bitwise.bsr(h, 8), Bitwise.band(h, 0xFF)}
  end

  defp normalize_ip(ip), do: ip

  defp ip_in_proxy?(ip, %{} = proxy), do: cidr_contains?(proxy, ip)

  defp trusted_proxies do
    Application.get_env(:tarakan, :trusted_proxies, [])
  end

  defp forwarded_headers do
    Application.get_env(:tarakan, :remote_ip_headers, ["x-forwarded-for"])
  end

  # Minimal IPv4/IPv6 CIDR matcher. Proxies are pre-parsed at config load.
  defp cidr_contains?(%{family: family, net: net, mask: mask}, ip)
       when tuple_size(ip) == tuple_size(net) do
    ip_int = ip_to_integer(ip)
    net_int = ip_to_integer(net)
    host_bits = if family == :inet, do: 32, else: 128
    shift = host_bits - mask

    if shift >= 0 do
      Bitwise.bsr(ip_int, shift) == Bitwise.bsr(net_int, shift)
    else
      false
    end
  end

  defp cidr_contains?(_proxy, _ip), do: false

  defp ip_to_integer({a, b, c, d}),
    do:
      Bitwise.bor(
        Bitwise.bor(Bitwise.bsl(a, 24), Bitwise.bsl(b, 16)),
        Bitwise.bor(Bitwise.bsl(c, 8), d)
      )

  defp ip_to_integer({a, b, c, d, e, f, g, h}) do
    [a, b, c, d, e, f, g, h]
    |> Enum.reduce(0, fn part, acc -> Bitwise.bor(Bitwise.bsl(acc, 16), part) end)
  end
end
