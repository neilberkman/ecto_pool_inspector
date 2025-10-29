defmodule InspectorTestHarnessWeb.Router do
  use InspectorTestHarnessWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {InspectorTestHarnessWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", InspectorTestHarnessWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # E2E test endpoints
  scope "/test", InspectorTestHarnessWeb do
    pipe_through :api

    get "/health", TestController, :health
    get "/hold-connections/:count", TestController, :hold_connections
    get "/crash-while-holding", TestController, :crash_while_holding
    get "/nested-transaction", TestController, :nested_transaction
    get "/trigger-snapshot", TestController, :trigger_snapshot
  end
end
