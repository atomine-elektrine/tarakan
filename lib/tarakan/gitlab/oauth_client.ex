defmodule Tarakan.GitLab.OAuthClient do
  @moduledoc false

  @callback exchange_code(String.t(), String.t(), String.t()) ::
              {:ok, String.t()} | {:error, :authorization_failed}

  @callback fetch_user(String.t()) :: {:ok, map()} | {:error, :authorization_failed}
end
