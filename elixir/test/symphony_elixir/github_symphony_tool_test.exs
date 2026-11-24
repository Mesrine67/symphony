defmodule SymphonyElixir.GitHub.SymphonyToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.SymphonyTool
  alias SymphonyElixir.Linear.Adapter, as: LinearAdapter

  test "Linear sessions advertise only the scoped GitHub publishing tools alongside Linear" do
    names = Enum.map(LinearAdapter.agent_tool_specs(), & &1["name"])

    assert names == ["linear_graphql", "github_publish_pr", "github_pr_checks"]
    refute "github_api" in names
  end

  test "Linear sessions remove tracker credentials from the Codex app-server environment" do
    settings = %{
      secret_environment_names: ["LINEAR_API_KEY"],
      provider: %{"repo" => "Mesrine67/hebergtonserv-desktop", "token" => "$GITHUB_TOKEN"}
    }

    names = LinearAdapter.secret_environment_names(settings)
    assert "LINEAR_API_KEY" in names
    assert "GITHUB_TOKEN" in names
    assert "GH_TOKEN" in names
  end

  test "publishes issue changes to its fixed branch and opens a PR against main" do
    test_pid = self()

    response =
      LinearAdapter.execute_agent_tool(
        "github_publish_pr",
        %{
          "title" => "Improve the settings panel",
          "body" => "Summary: improve settings.\n\nValidation: pnpm test.",
          "changes" => [%{"path" => "src/settings.ts", "content" => "export const setting = true;\n"}]
        },
        issue: %{identifier: "MIK-12"},
        tracker_settings: github_tracker_settings(),
        github_client: fn method, path, params, body, _opts ->
          send(test_pid, {:github_request, method, path, params, body})
          mock_response(method, path)
        end
      )

    assert response["success"]
    output = Jason.decode!(response["output"])
    assert output["repository"] == "Mesrine67/hebergtonserv-desktop"
    assert output["branch"] == "symphony/MIK-12"
    assert output["pull_request"]["number"] == 123

    assert_received {:github_request, "GET", "/repos/Mesrine67/hebergtonserv-desktop/git/ref/heads/symphony%2FMIK-12", %{}, nil}
    assert_received {:github_request, "GET", "/repos/Mesrine67/hebergtonserv-desktop/git/ref/heads/main", %{}, nil}
    assert_received {:github_request, "GET", "/repos/Mesrine67/hebergtonserv-desktop/git/commits/base-sha", %{}, nil}

    assert_received {:github_request, "POST", "/repos/Mesrine67/hebergtonserv-desktop/git/trees", %{},
                     %{
                       "base_tree" => "base-tree",
                       "tree" => [%{"path" => "src/settings.ts", "content" => "export const setting = true;\n"}]
                     }}

    assert_received {:github_request, "POST", "/repos/Mesrine67/hebergtonserv-desktop/git/commits", %{},
                     %{
                       "parents" => ["base-sha"],
                       "tree" => "new-tree"
                     }}

    assert_received {:github_request, "POST", "/repos/Mesrine67/hebergtonserv-desktop/git/refs", %{},
                     %{
                       "ref" => "refs/heads/symphony/MIK-12",
                       "sha" => "new-sha"
                     }}

    assert_received {:github_request, "GET", "/repos/Mesrine67/hebergtonserv-desktop/pulls",
                     %{
                       "head" => "Mesrine67:symphony/MIK-12",
                       "base" => "main",
                       "state" => "open"
                     }, nil}

    assert_received {:github_request, "POST", "/repos/Mesrine67/hebergtonserv-desktop/pulls", %{},
                     %{
                       "base" => "main",
                       "head" => "symphony/MIK-12",
                       "draft" => false
                     }}
  end

  test "routes pull request checks through the Linear adapter" do
    response =
      LinearAdapter.execute_agent_tool(
        "github_pr_checks",
        %{},
        issue: %{identifier: "MIK-7"},
        tracker_settings: github_tracker_settings(),
        github_client: fn method, path, _params, _body, _opts -> mock_response(method, path) end
      )

    assert response["success"]
    assert Jason.decode!(response["output"])["pull_request"] == nil
  end

  test "rejects another repository and unsafe paths before making a GitHub request" do
    settings = github_tracker_settings(%{"repo" => "another/repo"})

    response =
      SymphonyTool.execute(
        "github_publish_pr",
        publish_arguments(%{"path" => "src/file.ts", "content" => "safe"}),
        issue: %{identifier: "MIK-7"},
        tracker_settings: settings,
        github_client: fn _, _, _, _, _ -> flunk("must not contact GitHub") end
      )

    refute response["success"]
    assert Jason.decode!(response["output"])["error"]["message"] =~ "restricted"

    for path <- [".env.local", "config/id_rsa", "certs/app.pem", ".github/workflows/unsafe.yml"] do
      response =
        SymphonyTool.execute(
          "github_publish_pr",
          publish_arguments(%{"path" => path, "content" => "restricted"}),
          issue: %{identifier: "MIK-7"},
          tracker_settings: github_tracker_settings(),
          github_client: fn _, _, _, _, _ -> flunk("must not contact GitHub") end
        )

      refute response["success"], "publisher accepted restricted path #{path}"
    end
  end

  defp publish_arguments(change) do
    %{"title" => "A scoped change", "body" => "Summary and validation", "changes" => [change]}
  end

  defp github_tracker_settings(provider_overrides \\ %{}) do
    %{
      kind: "linear",
      provider: Map.merge(%{"repo" => "Mesrine67/hebergtonserv-desktop", "token" => "test-token"}, provider_overrides)
    }
  end

  defp mock_response("GET", "/repos/Mesrine67/hebergtonserv-desktop/git/ref/heads/symphony%2FMIK-12"),
    do: {:ok, %{status: 404, body: %{}}}

  defp mock_response("GET", "/repos/Mesrine67/hebergtonserv-desktop/git/ref/heads/main"),
    do: {:ok, %{status: 200, body: %{"object" => %{"sha" => "base-sha"}}}}

  defp mock_response("GET", "/repos/Mesrine67/hebergtonserv-desktop/git/commits/base-sha"),
    do: {:ok, %{status: 200, body: %{"tree" => %{"sha" => "base-tree"}}}}

  defp mock_response("POST", "/repos/Mesrine67/hebergtonserv-desktop/git/trees"),
    do: {:ok, %{status: 201, body: %{"sha" => "new-tree"}}}

  defp mock_response("POST", "/repos/Mesrine67/hebergtonserv-desktop/git/commits"),
    do: {:ok, %{status: 201, body: %{"sha" => "new-sha"}}}

  defp mock_response("POST", "/repos/Mesrine67/hebergtonserv-desktop/git/refs"),
    do: {:ok, %{status: 201, body: %{}}}

  defp mock_response("GET", "/repos/Mesrine67/hebergtonserv-desktop/pulls"),
    do: {:ok, %{status: 200, body: []}}

  defp mock_response("POST", "/repos/Mesrine67/hebergtonserv-desktop/pulls"),
    do: {:ok, %{status: 201, body: %{"number" => 123, "html_url" => "https://github.com/Mesrine67/hebergtonserv-desktop/pull/123"}}}
end
