defmodule TarakanWeb.Plugs.ClientIpTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Tarakan.TrustedProxies
  alias TarakanWeb.Plugs.ClientIp

  setup do
    previous = Application.get_env(:tarakan, :trusted_proxies, [])

    on_exit(fn ->
      Application.put_env(:tarakan, :trusted_proxies, previous)
    end)

    :ok
  end

  test "does not trust X-Forwarded-For without configured proxies" do
    Application.put_env(:tarakan, :trusted_proxies, [])

    conn =
      conn(:get, "/")
      |> Map.put(:remote_ip, {10, 0, 0, 5})
      |> put_req_header("x-forwarded-for", "203.0.113.9")
      |> ClientIp.call([])

    assert conn.remote_ip == {10, 0, 0, 5}
  end

  test "rewrites remote_ip when the peer is a trusted proxy" do
    Application.put_env(:tarakan, :trusted_proxies, TrustedProxies.parse("10.0.0.0/8"))

    conn =
      conn(:get, "/")
      |> Map.put(:remote_ip, {10, 0, 0, 5})
      |> put_req_header("x-forwarded-for", "203.0.113.9, 10.0.0.5")
      |> ClientIp.call([])

    assert conn.remote_ip == {203, 0, 113, 9}
  end

  test "ignores forwarded headers from untrusted peers" do
    Application.put_env(:tarakan, :trusted_proxies, TrustedProxies.parse("10.0.0.0/8"))

    conn =
      conn(:get, "/")
      |> Map.put(:remote_ip, {198, 51, 100, 1})
      |> put_req_header("x-forwarded-for", "203.0.113.9")
      |> ClientIp.call([])

    assert conn.remote_ip == {198, 51, 100, 1}
  end

  test "picks the rightmost untrusted hop, not a client-spoofed leftmost entry" do
    Application.put_env(:tarakan, :trusted_proxies, TrustedProxies.parse("10.0.0.0/8"))

    # Attacker sends a forged leftmost value; the trusted proxy appends the real
    # peer it observed. remote_ip must be the real hop, never the forged one.
    conn =
      conn(:get, "/")
      |> Map.put(:remote_ip, {10, 0, 0, 5})
      |> put_req_header("x-forwarded-for", "203.0.113.9, 198.51.100.7")
      |> ClientIp.call([])

    assert conn.remote_ip == {198, 51, 100, 7}
  end

  test "strips multiple trailing trusted proxies down to the client" do
    Application.put_env(:tarakan, :trusted_proxies, TrustedProxies.parse("10.0.0.0/8"))

    conn =
      conn(:get, "/")
      |> Map.put(:remote_ip, {10, 0, 0, 9})
      |> put_req_header("x-forwarded-for", "203.0.113.9, 10.0.0.5, 10.0.0.9")
      |> ClientIp.call([])

    assert conn.remote_ip == {203, 0, 113, 9}
  end

  test "matches an IPv4 trusted proxy against an IPv6-mapped IPv4 peer" do
    # On a dual-stack (`::`) listener, an IPv4 proxy arrives as ::ffff:10.0.0.5.
    Application.put_env(:tarakan, :trusted_proxies, TrustedProxies.parse("10.0.0.0/8"))

    conn =
      conn(:get, "/")
      |> Map.put(:remote_ip, {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0005})
      |> put_req_header("x-forwarded-for", "203.0.113.9")
      |> ClientIp.call([])

    assert conn.remote_ip == {203, 0, 113, 9}
  end

  test "normalizes an IPv6-mapped remote_ip to plain IPv4 for rate-limit keys" do
    conn = %Plug.Conn{remote_ip: {0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7109}}
    assert ClientIp.remote_ip_string(conn) == "203.0.113.9"
  end
end
