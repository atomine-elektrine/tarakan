defmodule Tarakan.Accounts.SshKey do
  @moduledoc """
  A public SSH key registered for git access.

  Keys are globally unique by SHA-256 fingerprint so a presented key resolves
  to exactly one account during SSH authentication. Only the public key is
  ever stored.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tarakan.Accounts.Account

  @accepted_types ~w(ssh-ed25519 ssh-rsa ecdsa-sha2-nistp256 ecdsa-sha2-nistp384 ecdsa-sha2-nistp521)
  @minimum_rsa_bits 3072

  schema "ssh_keys" do
    field :name, :string
    field :key_type, :string
    field :public_key, :string
    field :fingerprint_sha256, :string
    field :last_used_at, :utc_datetime_usec

    belongs_to :account, Account

    timestamps(type: :utc_datetime_usec)
  end

  def accepted_types, do: @accepted_types

  @doc false
  def changeset(ssh_key, attrs) do
    ssh_key
    |> cast(attrs, [:name, :public_key])
    |> validate_required([:name, :public_key])
    |> validate_length(:name, min: 1, max: 100)
    |> parse_public_key()
    |> unique_constraint(:fingerprint_sha256,
      message: "is already registered to an account"
    )
  end

  defp parse_public_key(changeset) do
    with pasted when is_binary(pasted) <- get_change(changeset, :public_key),
         {:ok, key, key_type} <- decode_public_key(pasted),
         :ok <- validate_strength(key) do
      changeset
      |> put_change(:public_key, normalize(key))
      |> put_change(:key_type, key_type)
      |> put_change(:fingerprint_sha256, fingerprint(key))
    else
      nil ->
        changeset

      {:error, :weak_key} ->
        add_error(changeset, :public_key, "RSA keys need at least #{@minimum_rsa_bits} bits")

      _error ->
        add_error(changeset, :public_key, "is not a supported OpenSSH public key")
    end
  end

  @doc "Decodes one OpenSSH public key line; rejects anything else."
  def decode_public_key(pasted) when is_binary(pasted) do
    line = String.trim(pasted)

    with [key_type, _blob | _comment] <- String.split(line, " ", parts: 3),
         true <- key_type in @accepted_types,
         {:ok, [{key, _attrs} | _rest]} <- safe_decode(line) do
      {:ok, key, key_type}
    else
      _other -> {:error, :invalid_key}
    end
  end

  defp safe_decode(line) do
    case :ssh_file.decode(line, :public_key) do
      decoded when is_list(decoded) -> {:ok, decoded}
      _error -> :error
    end
  rescue
    _error -> :error
  end

  defp validate_strength({:RSAPublicKey, modulus, _exponent}) do
    bits = modulus |> :binary.encode_unsigned() |> byte_size() |> Kernel.*(8)
    if bits >= @minimum_rsa_bits, do: :ok, else: {:error, :weak_key}
  end

  defp validate_strength(_key), do: :ok

  @doc "The canonical `SHA256:…` fingerprint for a decoded public key."
  def fingerprint(key) do
    :sha256
    |> :ssh.hostkey_fingerprint(key)
    |> to_string()
  end

  @doc "Re-encodes a decoded key as a normalized single-line authorized_keys entry."
  def normalize(key) do
    [{key, []}]
    |> :ssh_file.encode(:openssh_key)
    |> to_string()
    |> String.trim()
  end
end
