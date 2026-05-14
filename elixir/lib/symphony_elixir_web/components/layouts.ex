defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns =
      assigns
      |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())
      |> assign(:phoenix_html_js_path, public_path("/vendor/phoenix_html/phoenix_html.js"))
      |> assign(:phoenix_js_path, public_path("/vendor/phoenix/phoenix.js"))
      |> assign(:phoenix_live_view_js_path, public_path("/vendor/phoenix_live_view/phoenix_live_view.js"))
      |> assign(:live_socket_path, public_path("/live"))
      |> assign(:dashboard_css_path, public_path("/dashboard.css"))

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <meta name="live-socket-path" content={@live_socket_path} />
        <title>Symphony Observability</title>
        <script defer src={@phoenix_html_js_path}></script>
        <script defer src={@phoenix_js_path}></script>
        <script defer src={@phoenix_live_view_js_path}></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");
            var liveSocketPath = document
              .querySelector("meta[name='live-socket-path']")
              ?.getAttribute("content") || "/live";

            if (!window.Phoenix || !window.LiveView) return;

            var liveSocket = new window.LiveView.LiveSocket(liveSocketPath, window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken}
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="stylesheet" href={@dashboard_css_path} />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end

  defp public_path(path), do: SymphonyElixirWeb.PublicPath.path(path)
end
