defmodule Tarakan.AccountsTest do
  use Tarakan.DataCase, async: true

  alias Tarakan.Accounts

  test "creates and updates a GitHub identity without storing a token" do
    profile = %{
      provider_uid: 123_456,
      provider_login: "SignalUser",
      name: "First Name",
      avatar_url: "https://avatars.githubusercontent.com/u/123456",
      profile_url: "https://github.com/SignalUser"
    }

    assert {:ok, account} = Accounts.upsert_external_identity(:github, profile)
    assert account.handle == "signaluser"
    assert is_nil(account.display_name)

    assert {:ok, updated_account} =
             Accounts.upsert_external_identity(:github, %{profile | name: "Updated Name"})

    assert updated_account.id == account.id

    identity = Tarakan.Repo.get_by!(Tarakan.Accounts.Identity, account_id: account.id)
    assert identity.name == "Updated Name"
    refute Map.has_key?(Map.from_struct(identity), :access_token)
  end

  test "links a GitHub identity to an existing native account" do
    account = account_fixture()

    profile = %{
      provider_uid: 982_451,
      provider_login: "NativeSignal",
      name: "Native Signal",
      avatar_url: "https://avatars.githubusercontent.com/u/982451",
      profile_url: "https://github.com/NativeSignal"
    }

    assert {:ok, linked_account} =
             Accounts.upsert_external_identity(:github, profile, account)

    assert linked_account.id == account.id

    assert %Tarakan.Accounts.Identity{account_id: account_id, provider: "github"} =
             Tarakan.Repo.get_by!(Tarakan.Accounts.Identity,
               provider: "github",
               provider_uid: "982451"
             )

    assert account_id == account.id
  end

  test "does not move an identity between accounts" do
    profile = %{
      provider_uid: 741_852,
      provider_login: "BoundSignal",
      name: "Bound Signal",
      avatar_url: "https://avatars.githubusercontent.com/u/741852",
      profile_url: "https://github.com/BoundSignal"
    }

    assert {:ok, owner} = Accounts.upsert_external_identity(:github, profile)
    other_account = account_fixture()

    assert {:error, :identity_already_linked} =
             Accounts.upsert_external_identity(:github, profile, other_account)

    assert {:ok, same_owner} = Accounts.upsert_external_identity(:github, profile)
    assert same_owner.id == owner.id
  end

  test "creates valid handles for short and reserved forge usernames" do
    base_profile = %{
      name: nil,
      avatar_url: nil,
      profile_url: "https://github.com/a"
    }

    assert {:ok, short_account} =
             Accounts.upsert_external_identity(
               :github,
               Map.merge(base_profile, %{provider_uid: 101, provider_login: "a"})
             )

    assert short_account.handle == "a-id"

    assert {:ok, reserved_account} =
             Accounts.upsert_external_identity(
               :github,
               Map.merge(base_profile, %{
                 provider_uid: 102,
                 provider_login: "root",
                 profile_url: "https://github.com/root"
               })
             )

    assert reserved_account.handle == "root-user"
  end

  import Tarakan.AccountsFixtures
  alias Tarakan.Accounts.{Account, AccountToken}

  describe "get_account_by_email/1" do
    test "does not return the account if the email does not exist" do
      refute Accounts.get_account_by_email("unknown@example.com")
    end

    test "returns the account if the email exists" do
      %{id: id} = account = account_fixture()
      assert %Account{id: ^id} = Accounts.get_account_by_email(account.email)
    end
  end

  describe "get_account_by_email_and_password/2" do
    test "does not return the account if the email does not exist" do
      refute Accounts.get_account_by_email_and_password("unknown@example.com", "hello world!")
    end

    test "does not return the account if the password is not valid" do
      account = account_fixture() |> set_password()
      refute Accounts.get_account_by_email_and_password(account.email, "invalid")
    end

    test "returns the account if the email and password are valid" do
      %{id: id} = account = account_fixture() |> set_password()

      assert %Account{id: ^id} =
               Accounts.get_account_by_email_and_password(account.email, valid_account_password())
    end
  end

  describe "get_account_by_identifier_and_password/2" do
    test "accepts either a handle or email for a confirmed account" do
      account = account_fixture() |> set_password()

      assert %Account{id: id} =
               Accounts.get_account_by_identifier_and_password(
                 String.upcase(account.handle),
                 valid_account_password()
               )

      assert id == account.id

      assert %Account{id: ^id} =
               Accounts.get_account_by_identifier_and_password(
                 String.upcase(account.email),
                 valid_account_password()
               )
    end

    test "accepts password login without email confirmation" do
      account = unconfirmed_account_fixture()

      {:ok, {account, _tokens}} =
        Accounts.update_account_password(account, %{password: valid_account_password()})

      assert %Account{id: id} =
               Accounts.get_account_by_identifier_and_password(
                 account.handle,
                 valid_account_password()
               )

      assert id == account.id
    end
  end

  describe "get_account!/1" do
    test "raises if id is invalid" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_account!(-1)
      end
    end

    test "returns the account with the given id" do
      %{id: id} = account = account_fixture()
      assert %Account{id: ^id} = Accounts.get_account!(account.id)
    end
  end

  describe "register_account/1" do
    test "requires email to be set" do
      {:error, changeset} = Accounts.register_account(%{})

      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates email when given" do
      {:error, changeset} = Accounts.register_account(%{email: "not valid"})

      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
    end

    test "validates maximum values for email for security" do
      too_long = String.duplicate("db", 100)
      {:error, changeset} = Accounts.register_account(%{email: too_long})
      assert "should be at most 160 character(s)" in errors_on(changeset).email
    end

    test "validates email uniqueness" do
      %{email: email} = account_fixture()
      {:error, changeset} = Accounts.register_account(%{email: email})
      assert "has already been taken" in errors_on(changeset).email

      # Now try with the uppercased email too, to check that email case is ignored.
      {:error, changeset} = Accounts.register_account(%{email: String.upcase(email)})
      assert "has already been taken" in errors_on(changeset).email
    end

    test "registers accounts without password" do
      email = unique_account_email()
      {:ok, account} = Accounts.register_account(valid_account_attributes(email: email))
      assert account.email == email
      assert is_nil(account.hashed_password)
      assert account.confirmed_at
      assert is_nil(account.password)
    end

    test "normalizes and protects public handles" do
      assert {:ok, account} =
               Accounts.register_account(valid_account_attributes(handle: "  Signal_Ghost  "))

      assert account.handle == "signal_ghost"

      assert {:error, reserved} =
               Accounts.register_account(valid_account_attributes(handle: "SECURITY"))

      assert "is reserved" in errors_on(reserved).handle

      assert {:error, duplicate} =
               Accounts.register_account(
                 valid_account_attributes(handle: String.upcase(account.handle))
               )

      assert "has already been taken" in errors_on(duplicate).handle
    end
  end

  describe "request_registration/2" do
    test "creates an active account and delivers a login link for new credentials" do
      email = unique_account_email()
      attrs = valid_account_attributes(email: email)

      assert {:ok, {:created, registration_token}} =
               Accounts.request_registration(attrs, fn token ->
                 "http://localhost/accounts/log-in/#{token}"
               end)

      account = Accounts.get_account_by_email(email)
      assert %Account{confirmed_at: %DateTime{}} = account

      assert Accounts.get_account_by_magic_link_token(registration_token).id == account.id

      assert Repo.aggregate(
               from(t in AccountToken,
                 where:
                   t.account_id == ^account.id and t.context == "login" and t.sent_to == ^email
               ),
               :count
             ) == 2
    end

    test "notifies an existing email without creating a second account" do
      %{email: email, id: account_id} = account_fixture()
      attrs = valid_account_attributes(email: email)

      login_tokens_before =
        Repo.aggregate(
          from(t in AccountToken, where: t.account_id == ^account_id and t.context == "login"),
          :count
        )

      assert {:ok, :accepted} =
               Accounts.request_registration(attrs, fn token ->
                 "http://localhost/accounts/log-in/#{token}"
               end)

      assert [%{id: ^account_id}] =
               Repo.all(from a in Account, where: a.email == ^email)

      login_tokens_after =
        Repo.aggregate(
          from(t in AccountToken, where: t.account_id == ^account_id and t.context == "login"),
          :count
        )

      assert login_tokens_after == login_tokens_before + 1
    end

    test "accepts a taken handle without creating an account or revealing the conflict" do
      %{handle: handle, id: account_id} = account_fixture()
      email = unique_account_email()
      attrs = valid_account_attributes(handle: handle, email: email)

      login_tokens_before =
        Repo.aggregate(
          from(t in AccountToken, where: t.account_id == ^account_id and t.context == "login"),
          :count
        )

      assert {:ok, :accepted} =
               Accounts.request_registration(attrs, fn token ->
                 "http://localhost/accounts/log-in/#{token}"
               end)

      refute Accounts.get_account_by_email(email)

      login_tokens_after =
        Repo.aggregate(
          from(t in AccountToken, where: t.account_id == ^account_id and t.context == "login"),
          :count
        )

      assert login_tokens_after == login_tokens_before
    end

    test "still returns non-uniqueness validation errors" do
      assert {:error, changeset} =
               Accounts.request_registration(%{handle: "ab", email: "not valid"}, fn _ ->
                 "http://localhost"
               end)

      assert "must have the @ sign and no spaces" in errors_on(changeset).email
      refute "has already been taken" in List.wrap(errors_on(changeset)[:handle])
      refute "has already been taken" in List.wrap(errors_on(changeset)[:email])
    end

    test "strips uniqueness errors when mixed with format errors" do
      %{email: email} = account_fixture()

      assert {:error, changeset} =
               Accounts.request_registration(
                 %{handle: "!!", email: email},
                 fn _ -> "http://localhost" end
               )

      errors = errors_on(changeset)
      refute "has already been taken" in List.wrap(errors[:email])
      refute "has already been taken" in List.wrap(errors[:handle])
      assert errors[:handle]
    end
  end

  describe "sudo_mode?/2" do
    test "validates the authenticated_at time" do
      now = DateTime.utc_now()

      assert Accounts.sudo_mode?(%Account{authenticated_at: DateTime.utc_now()})
      # Default window is two hours.
      assert Accounts.sudo_mode?(%Account{authenticated_at: DateTime.add(now, -60, :minute)})
      refute Accounts.sudo_mode?(%Account{authenticated_at: DateTime.add(now, -3, :hour)})

      # Explicit shorter window still works for callers that need it.
      refute Accounts.sudo_mode?(
               %Account{authenticated_at: DateTime.add(now, -11, :minute)},
               -10
             )

      # not authenticated
      refute Accounts.sudo_mode?(%Account{})
    end
  end

  describe "change_account_email/3" do
    test "returns a account changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_account_email(%Account{})
      assert changeset.required == [:email]
    end
  end

  describe "deliver_account_update_email_instructions/3" do
    setup do
      %{account: account_fixture()}
    end

    test "sends token through notification", %{account: account} do
      token =
        extract_account_token(fn url ->
          Accounts.deliver_account_update_email_instructions(account, "current@example.com", url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert account_token = Repo.get_by(AccountToken, token: :crypto.hash(:sha256, token))
      assert account_token.account_id == account.id
      assert account_token.sent_to == account.email
      assert account_token.context == "change:current@example.com"
    end
  end

  describe "update_account_email/2" do
    setup do
      account = unconfirmed_account_fixture()
      email = unique_account_email()

      token =
        extract_account_token(fn url ->
          Accounts.deliver_account_update_email_instructions(
            %{account | email: email},
            account.email,
            url
          )
        end)

      %{account: account, token: token, email: email}
    end

    test "updates the email with a valid token", %{account: account, token: token, email: email} do
      assert {:ok, %{email: ^email}} = Accounts.update_account_email(account, token)
      changed_account = Repo.get!(Account, account.id)
      assert changed_account.email != account.email
      assert changed_account.email == email
      refute Repo.get_by(AccountToken, account_id: account.id)
    end

    test "does not update email with invalid token", %{account: account} do
      assert Accounts.update_account_email(account, "oops") ==
               {:error, :transaction_aborted}

      assert Repo.get!(Account, account.id).email == account.email
      assert Repo.get_by(AccountToken, account_id: account.id)
    end

    test "does not update email if account email changed", %{account: account, token: token} do
      assert Accounts.update_account_email(%{account | email: "current@example.com"}, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(Account, account.id).email == account.email
      assert Repo.get_by(AccountToken, account_id: account.id)
    end

    test "does not update email if token expired", %{account: account, token: token} do
      {1, nil} = Repo.update_all(AccountToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])

      assert Accounts.update_account_email(account, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(Account, account.id).email == account.email
      assert Repo.get_by(AccountToken, account_id: account.id)
    end
  end

  describe "change_account_password/3" do
    test "returns a account changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_account_password(%Account{})
      assert changeset.required == [:password]
    end

    test "allows fields to be set" do
      changeset =
        Accounts.change_account_password(
          %Account{},
          %{
            "password" => "new valid password"
          },
          hash_password: false
        )

      assert changeset.valid?
      assert get_change(changeset, :password) == "new valid password"
      assert is_nil(get_change(changeset, :hashed_password))
    end
  end

  describe "update_account_password/2" do
    setup do
      %{account: account_fixture()}
    end

    test "validates password", %{account: account} do
      {:error, changeset} =
        Accounts.update_account_password(account, %{
          password: "not valid",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 15 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "validates maximum values for password for security", %{account: account} do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Accounts.update_account_password(account, %{password: too_long})

      assert "should be at most 128 character(s)" in errors_on(changeset).password
    end

    test "updates the password", %{account: account} do
      {:ok, {account, disconnect_ref}} =
        Accounts.update_account_password(account, %{
          password: "new valid password"
        })

      assert disconnect_ref == account.id
      assert is_nil(account.password)
      assert Accounts.get_account_by_email_and_password(account.email, "new valid password")
    end

    test "deletes sessions and revokes client credentials for the given account", %{
      account: account
    } do
      _ = Accounts.generate_account_session_token(account)
      api_token = Accounts.create_account_api_token(account)

      {:ok, {_, _}} =
        Accounts.update_account_password(account, %{
          password: "new valid password"
        })

      refute Repo.get_by(AccountToken, account_id: account.id)
      assert :error = Accounts.fetch_account_by_api_token(api_token)
    end
  end

  describe "generate_account_session_token/1" do
    setup do
      %{account: account_fixture()}
    end

    test "generates a token", %{account: account} do
      token = Accounts.generate_account_session_token(account)
      hashed = AccountToken.hash_token(token)
      assert account_token = Repo.get_by(AccountToken, token: hashed)
      assert account_token.context == "session"
      assert account_token.authenticated_at != nil
      # Only the hash is stored.
      refute account_token.token == token

      # Creating the same token hash for another account should fail
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%AccountToken{
          token: account_token.token,
          account_id: account_fixture().id,
          context: "session"
        })
      end
    end

    test "duplicates the authenticated_at of given account in new token", %{account: account} do
      account = %{account | authenticated_at: DateTime.add(DateTime.utc_now(:second), -3600)}
      token = Accounts.generate_account_session_token(account)
      assert account_token = Repo.get_by(AccountToken, token: AccountToken.hash_token(token))
      assert account_token.authenticated_at == account.authenticated_at
      assert DateTime.compare(account_token.inserted_at, account.authenticated_at) == :gt
    end
  end

  describe "get_account_by_session_token/1" do
    setup do
      account = account_fixture()
      token = Accounts.generate_account_session_token(account)
      %{account: account, token: token}
    end

    test "returns account by token", %{account: account, token: token} do
      assert {session_account, token_inserted_at} = Accounts.get_account_by_session_token(token)
      assert session_account.id == account.id
      assert session_account.authenticated_at != nil
      assert token_inserted_at != nil
    end

    test "does not return account for invalid token" do
      refute Accounts.get_account_by_session_token("oops")
    end

    test "does not return account for expired token", %{token: token} do
      dt = ~N[2020-01-01 00:00:00]
      {1, nil} = Repo.update_all(AccountToken, set: [inserted_at: dt, authenticated_at: dt])
      refute Accounts.get_account_by_session_token(token)
    end
  end

  describe "get_account_by_magic_link_token/1" do
    setup do
      account = account_fixture()
      {encoded_token, _hashed_token} = generate_account_magic_link_token(account)
      %{account: account, token: encoded_token}
    end

    test "returns account by token", %{account: account, token: token} do
      assert session_account = Accounts.get_account_by_magic_link_token(token)
      assert session_account.id == account.id
    end

    test "does not return account for invalid token" do
      refute Accounts.get_account_by_magic_link_token("oops")
    end

    test "does not return account for expired token", %{token: token} do
      {1, nil} = Repo.update_all(AccountToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      refute Accounts.get_account_by_magic_link_token(token)
    end
  end

  describe "login_account_by_magic_link/1" do
    test "confirms account and expires tokens" do
      account = unconfirmed_account_fixture()
      refute account.confirmed_at
      {encoded_token, _hashed_token} = generate_account_magic_link_token(account)

      assert {:ok, {account, account_id}} = Accounts.login_account_by_magic_link(encoded_token)
      assert account_id == account.id
      assert account.confirmed_at
    end

    test "returns account and (deleted) token for confirmed account" do
      account = account_fixture()
      assert account.confirmed_at
      {encoded_token, _hashed_token} = generate_account_magic_link_token(account)
      assert {:ok, {^account, []}} = Accounts.login_account_by_magic_link(encoded_token)
      # one time use only
      assert {:error, :not_found} = Accounts.login_account_by_magic_link(encoded_token)
    end

    test "logs in a legacy unconfirmed account with a password set" do
      account = unconfirmed_account_fixture()
      {1, nil} = Repo.update_all(Account, set: [hashed_password: "hashed"])
      {encoded_token, _hashed_token} = generate_account_magic_link_token(account)

      assert {:ok, {logged_in, account_id}} =
               Accounts.login_account_by_magic_link(encoded_token)

      assert logged_in.id == account.id
      assert logged_in.confirmed_at
      assert account_id == account.id
    end
  end

  describe "delete_account_session_token/1" do
    test "deletes the token" do
      account = account_fixture()
      token = Accounts.generate_account_session_token(account)
      assert Accounts.delete_account_session_token(token) == :ok
      refute Accounts.get_account_by_session_token(token)
    end
  end

  describe "deliver_login_instructions/2" do
    setup do
      %{account: unconfirmed_account_fixture()}
    end

    test "sends token through notification", %{account: account} do
      token =
        extract_account_token(fn url ->
          Accounts.deliver_login_instructions(account, url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert account_token = Repo.get_by(AccountToken, token: :crypto.hash(:sha256, token))
      assert account_token.account_id == account.id
      assert account_token.sent_to == account.email
      assert account_token.context == "login"
    end
  end

  describe "inspect/2 for the Account module" do
    test "does not include password" do
      refute inspect(%Account{password: "123456"}) =~ "password: \"123456\""
    end
  end

  describe "API tokens" do
    test "create_account_api_token/1 returns a token that fetches the account" do
      account = account_fixture()
      token = Accounts.create_account_api_token(account)

      assert {:ok, fetched} = Accounts.fetch_account_by_api_token(token)
      assert fetched.id == account.id
    end

    test "credentials coexist and can be revoked independently" do
      account = account_fixture()
      old_token = Accounts.create_account_api_token(account)
      new_token = Accounts.create_account_api_token(account)

      assert {:ok, _account} = Accounts.fetch_account_by_api_token(old_token)
      assert {:ok, _account} = Accounts.fetch_account_by_api_token(new_token)

      [newest, oldest] = Tarakan.Accounts.ApiCredentials.list(account)
      assert {:ok, _credential} = Tarakan.Accounts.ApiCredentials.revoke(account, oldest.id)
      assert :error = Accounts.fetch_account_by_api_token(old_token)
      assert {:ok, _account} = Accounts.fetch_account_by_api_token(new_token)
      assert newest.revoked_at == nil
    end

    test "fetch_account_by_api_token/1 rejects garbage" do
      assert :error = Accounts.fetch_account_by_api_token("not-a-token")
      assert :error = Accounts.fetch_account_by_api_token(nil)
    end
  end
end
