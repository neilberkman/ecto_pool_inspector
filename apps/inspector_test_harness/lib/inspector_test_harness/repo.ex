defmodule InspectorTestHarness.Repo do
  use Ecto.Repo,
    otp_app: :inspector_test_harness,
    adapter: Ecto.Adapters.Postgres
end
