defmodule Phoenix.LiveView.HooksTest do
  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Phoenix.LiveView
  alias Phoenix.LiveViewTest.{Endpoint, HooksLive}

  @endpoint Endpoint

  setup do
    {:ok, conn: Plug.Test.init_test_session(build_conn(), %{})}
  end

  test "on_mount hook raises when hook result is invalid", %{conn: conn} do
    assert_raise Plug.Conn.WrapperError,
                 ~r(invalid return from hook {Phoenix.LiveViewTest.HooksLive.BadMount, :default}),
                 fn ->
                   live(conn, "/lifecycle/bad-mount")
                 end
  end

  test "on_mount hooks are invoked in the order they are declared", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/lifecycle")

    assigns = HooksLive.run(lv, fn socket -> {:reply, socket.assigns, socket} end)

    assert assigns.init_assigns_mount
    assert assigns.init_assigns_other_mount
    assert assigns.last_on_mount == :init_assigns_other_mount
  end

  test "on_mount hook raises when :halt is returned without a redirected socket", %{conn: conn} do
    assert_raise Plug.Conn.WrapperError,
                 ~r(the hook {Phoenix.LiveViewTest.HooksLive.HaltMount, :hook} for lifecycle event :mount attempted to halt without redirecting.),
                 fn ->
                   live(conn, "/lifecycle/halt-mount")
                 end
  end

  test "on_mount hook raises when :cont is returned with a redirected socket", %{conn: conn} do
    assert_raise Plug.Conn.WrapperError,
                 ~r(the hook {Phoenix.LiveViewTest.HooksLive.RedirectMount, :default} for lifecycle event :mount attempted to redirect without halting.),
                 fn ->
                   live(conn, "/lifecycle/redirect-cont-mount")
                 end
  end

  test "on_mount hook halts with redirected socket", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/lifecycle"}}} =
             live(conn, "/lifecycle/redirect-halt-mount")
  end

  test "handle_event/3 raises when hook result is invalid", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/lifecycle")

    HooksLive.attach_hook(lv, :boom, :handle_event, fn _, _, _ -> :boom end)

    assert HooksLive.exits_with(lv, ArgumentError, fn ->
             lv |> element("#inc") |> render_click()
           end) =~ "Got: :boom"
  end

  test "handle_event/3 halt and continue", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/lifecycle")

    assert lv |> element("#inc") |> render_click() =~ "count:1"
    assert lv |> element("#inc") |> render_click() =~ "count:2"

    HooksLive.attach_hook(lv, :multiply_inc, :handle_event, fn
      "inc", _, socket ->
        {:halt, LiveView.update(socket, :count, &(&1 * 2))}

      "dec", _, socket ->
        {:cont, socket}
    end)

    assert lv |> element("#inc") |> render_click() =~ "count:4"
    assert lv |> element("#inc") |> render_click() =~ "count:8"

    assert lv |> element("#dec") |> render_click() =~ "count:7"
    assert lv |> element("#dec") |> render_click() =~ "count:6"

    HooksLive.detach_hook(lv, :multiply_inc, :handle_event)

    assert lv |> element("#inc") |> render_click() =~ "count:7"
    assert lv |> element("#inc") |> render_click() =~ "count:8"
  end

  test "handle_params/3 raises when hook result is invalid", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/lifecycle")

    HooksLive.attach_hook(lv, :boom, :handle_params, fn _, _, _ -> :boom end)

    assert HooksLive.exits_with(lv, ArgumentError, fn ->
             lv |> element("#patch") |> render_click()
           end) =~ "Got: :boom"
  end

  test "handle_params/3 attached after connected", %{conn: conn} do
    {:ok, lv, html} = live(conn, "/lifecycle")
    assert html =~ "params_hook:\n"

    HooksLive.attach_hook(lv, :hook, :handle_params, fn
      _params, _uri, %{assigns: %{params_hook_ref: _}} = socket ->
        {:halt, LiveView.update(socket, :params_hook_ref, &(&1 + 1))}

      _params, _uri, socket ->
        {:halt, LiveView.assign(socket, :params_hook_ref, 0)}
    end)

    lv |> element("#patch") |> render_click() =~ "params_hook:0"
    lv |> element("#patch") |> render_click() =~ "params_hook:1"

    HooksLive.detach_hook(lv, :hook, :handle_params)

    assert render(lv) =~ "params_hook:1"
  end

  test "handle_params/3 without module callback", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/lifecycle/handle-params-not-defined")
    assert render(lv) =~ "url=http://www.example.com/lifecycle/handle-params-not-defined"
  end

  test "handle_params/3 when callback is not exported raises without halt", %{conn: conn} do
    {:ok, lv, html} = live(conn, "/lifecycle")
    assert html =~ "params_hook:\n"

    HooksLive.attach_hook(lv, :hook, :handle_params, fn
      _params, _uri, %{assigns: %{params_hook_ref: 0}} = socket ->
        {:halt, LiveView.update(socket, :params_hook_ref, &(&1 + 1))}

      _params, _uri, %{assigns: %{params_hook_ref: 1}} = socket ->
        {:cont, socket}

      _params, _uri, socket ->
        {:halt, LiveView.assign(socket, :params_hook_ref, 0)}
    end)

    lv |> element("#patch") |> render_click() =~ "params_hook:0"
    lv |> element("#patch") |> render_click() =~ "params_hook:1"

    HooksLive.detach_hook(lv, :hook, :handle_params)

    Process.flag(:trap_exit, true)

    assert ExUnit.CaptureLog.capture_log(fn ->
             try do
               lv |> element("#patch") |> render_click()
             catch
               :exit, _ -> :ok
             end
           end) =~
             "** (UndefinedFunctionError) function Phoenix.LiveViewTest.HooksLive.handle_params/3 is undefined"
  end

  test "handle_info/2 raises when hook result is invalid", %{conn: conn} do
    Process.flag(:trap_exit, true)

    {:ok, lv, _html} = live(conn, "/lifecycle")
    HooksLive.attach_hook(lv, :boom, :handle_info, fn _, _ -> :boom end)

    assert ExUnit.CaptureLog.capture_log(fn ->
             send(lv.pid, :noop)
             ref = Process.monitor(lv.pid)
             assert_receive {:DOWN, ^ref, _, _, _}
           end) =~
             "** (ArgumentError) invalid return from hook :boom for lifecycle event :handle_info."
  end

  test "handle_info/2 attached and detached", %{conn: conn} do
    assert {:ok, lv, _html} = live(conn, "/lifecycle")

    ref = make_ref()
    send(lv.pid, {:ping, ref, self()})

    assert_receive {:pong, ^ref}

    HooksLive.attach_hook(lv, :hitm, :handle_info, fn {:ping, ref, pid}, socket ->
      send(pid, {:intercepted, ref})
      {:halt, socket}
    end)

    ref = make_ref()
    send(lv.pid, {:ping, ref, self()})

    assert_receive {:intercepted, ^ref}
    refute_received {:pong, ^ref}

    HooksLive.detach_hook(lv, :hitm, :handle_info)

    ref = make_ref()
    send(lv.pid, {:ping, ref, self()})

    assert_receive {:pong, ^ref}
    refute_received {:intercepted, ^ref}
  end

  test "handle_info/3 without module callback", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/lifecycle/handle-info-not-defined")
    assert render(lv) =~ "data=somedata"
  end

  test "attach_hook raises when given a live component socket", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/lifecycle/components")

    assert HooksLive.exits_with(lv, ArgumentError, fn ->
      lv |> element("#attach") |> render_click()
    end) =~ "lifecycle hooks are not supported on stateful components."
  end

  test "detach_hook raises when given a live component socket", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/lifecycle/components")

    assert HooksLive.exits_with(lv, ArgumentError, fn ->
      lv |> element("#detach") |> render_click()
    end) =~ "lifecycle hooks are not supported on stateful components."
  end

  test "stage_info", %{conn: conn} do
    alias Phoenix.LiveView.Lifecycle
    {:ok, lv, _html} = live(conn, "/lifecycle")

    socket = HooksLive.run(lv, fn socket -> {:reply, socket, socket} end)

    assert Lifecycle.stage_info(socket, HooksLive, :mount, 3) == %{
             any?: true,
             callbacks?: true,
             exported?: true
           }

    assert Lifecycle.stage_info(socket, HooksLive, :handle_params, 3) == %{
             any?: false,
             callbacks?: false,
             exported?: false
           }

    assert Lifecycle.stage_info(socket, HooksLive, :handle_event, 3) == %{
             any?: true,
             callbacks?: false,
             exported?: true
           }

    assert Lifecycle.stage_info(socket, HooksLive, :handle_info, 2) == %{
             any?: true,
             callbacks?: false,
             exported?: true
           }

    HooksLive.attach_hook(lv, :ok, :handle_params, fn _, _, socket ->
      {:cont, socket}
    end)

    socket = HooksLive.run(lv, fn socket -> {:reply, socket, socket} end)

    assert Lifecycle.stage_info(socket, HooksLive, :handle_params, 3) == %{
             any?: true,
             callbacks?: true,
             exported?: false
           }
  end
end
