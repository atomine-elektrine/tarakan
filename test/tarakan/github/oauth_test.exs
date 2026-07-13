defmodule Tarakan.GitHub.OAuthTest do
  use ExUnit.Case, async: true

  alias Tarakan.GitHub.OAuth

  test "generates valid PKCE material and compares state securely" do
    state = OAuth.generate_state()
    {verifier, challenge} = OAuth.generate_pkce()

    assert byte_size(state) >= 43
    assert byte_size(verifier) >= 43
    assert byte_size(challenge) == 43
    assert OAuth.valid_state?(state, state)
    refute OAuth.valid_state?(state, OAuth.generate_state())
    refute OAuth.valid_state?(state, nil)
  end
end
