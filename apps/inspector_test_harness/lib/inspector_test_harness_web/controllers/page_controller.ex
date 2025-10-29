defmodule InspectorTestHarnessWeb.PageController do
  use InspectorTestHarnessWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
