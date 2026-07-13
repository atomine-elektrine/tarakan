defmodule Tarakan.TrustedProxies do
  @moduledoc false

  @doc """
  Parses a comma-separated list of IPs or CIDRs into internal proxy specs.

  Examples: `"127.0.0.1,10.0.0.0/8,::1"`.
  """
  def parse(nil), do: []
  def parse(""), do: []

  def parse(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(&parse_one/1)
  end

  def parse(list) when is_list(list), do: Enum.flat_map(list, &parse_one(to_string(&1)))

  defp parse_one(entry) do
    case String.split(entry, "/", parts: 2) do
      [ip] ->
        case parse_address(ip) do
          {:ok, addr, family} ->
            mask = if family == :inet, do: 32, else: 128
            [%{family: family, net: addr, mask: mask}]

          :error ->
            []
        end

      [ip, mask_str] ->
        with {:ok, addr, family} <- parse_address(ip),
             {mask, ""} <- Integer.parse(mask_str),
             true <- mask >= 0 and mask <= if(family == :inet, do: 32, else: 128) do
          [%{family: family, net: addr, mask: mask}]
        else
          _invalid -> []
        end
    end
  end

  defp parse_address(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, addr} when tuple_size(addr) == 4 -> {:ok, addr, :inet}
      {:ok, addr} when tuple_size(addr) == 8 -> {:ok, addr, :inet6}
      _error -> :error
    end
  end
end
