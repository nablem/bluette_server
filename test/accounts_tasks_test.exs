defmodule BluetteServer.AccountsTasksTest do
  use ExUnit.Case, async: false

  alias BluetteServer.Accounts
  alias BluetteServer.Accounts.User
  alias BluetteServer.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Repo.delete_all(User)
    :ok
  end

  test "seed_fake_profiles inserts completed fake profiles" do
    assert Accounts.seed_fake_profiles(30) == 30
    assert Accounts.count_users() == 30

    seeded_users = Accounts.list_seeded_users()
    assert length(seeded_users) == 30

    assert Enum.all?(seeded_users, fn user ->
             user.age in 18..120 and
               user.gender in ["male", "female", "other"] and
               user.profile_picture ==
                 "https://dessindigo.com/storage/images/posts/bob-eponge/dessin-bob-eponge.webp" and
               user.audio_bio ==
                 "https://upload.wikimedia.org/wikipedia/commons/1/1f/Fundaci%C3%B3n_Joaqu%C3%ADn_D%C3%ADaz_-_ATO_00446_13_-_Rosario_de_Las_quince_rosas_de_Mar%C3%ADa.ogg" and
               user.latitude == 48.867178137901746 and
               user.longitude == 2.2688445113445654 and
               user.pref_min_age in 18..40 and
               user.pref_max_age in 23..120 and
               user.pref_max_age >= user.pref_min_age and
               user.pref_max_distance_km in [5, 10, 25, 50, 100] and
               user.pref_gender in ["male", "female", "everyone"] and
               not is_nil(user.name)
           end)
  end

  test "clear_user_details removes onboarding details for an existing user" do
    {:ok, _user} = Accounts.get_or_create_from_claims(%{uid: "user_1", email: "user1@example.com"})
    {:ok, user} = Accounts.get_user_by_uid("user_1") |> Accounts.update_name(%{"name" => "Nabil"})
    {:ok, user} = Accounts.update_age(user, %{"age" => 28})
    {:ok, user} = Accounts.update_audio_bio(user, %{"audio_bio" => "https://firebasestorage.googleapis.com/v0/b/bluette/o/audio1.m4a"})
    {:ok, _user} = Accounts.update_profile_picture(user, %{"profile_picture" => "https://firebasestorage.googleapis.com/v0/b/bluette/o/selfie1.jpg"})

    assert {:ok, cleared_user} = Accounts.clear_user_details("user_1")
    assert cleared_user.name == nil
    assert cleared_user.age == nil
    assert cleared_user.audio_bio == nil
    assert cleared_user.profile_picture == nil
  end

  test "mix bluette.seed_fake_profiles seeds the requested number of users" do
    Mix.Task.reenable("bluette.seed_fake_profiles")
    Mix.Tasks.Bluette.SeedFakeProfiles.run(["5"])

    assert Accounts.count_users() == 5
  end
end
