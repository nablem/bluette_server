defmodule BluetteServer.Repo.Migrations.AddHomepageMatching do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :visibility_rank, :integer, default: 100, null: false
    end

    create table(:swipes) do
      add :swiper_user_id, references(:users, on_delete: :delete_all), null: false
      add :swiped_user_id, references(:users, on_delete: :delete_all), null: false
      add :decision, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:swipes, [:swiper_user_id, :swiped_user_id])
    create index(:swipes, [:swiped_user_id, :decision])

    create table(:meetings) do
      add :user_a_id, references(:users, on_delete: :delete_all), null: false
      add :user_b_id, references(:users, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "upcoming"
      add :scheduled_for, :utc_datetime, null: false
      add :place_name, :string, null: false
      add :place_latitude, :float
      add :place_longitude, :float
      add :cancelled_by_user_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:meetings, [:user_a_id, :status, :scheduled_for])
    create index(:meetings, [:user_b_id, :status, :scheduled_for])

  end
end
