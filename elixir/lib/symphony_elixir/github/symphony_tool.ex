defmodule SymphonyElixir.GitHub.SymphonyTool do
  @moduledoc """
  Restricted GitHub tools for Symphony's Linear workflow.

  All writes are limited to one configured repository, one issue-derived branch,
  and opening or updating a pull request against `main`.
  """

  alias SymphonyElixir.GitHub.Client

  @repository "Mesrine67/hebergtonserv-desktop"
  @base_branch "main"
  @publish_tool "github_publish_pr"
  @checks_tool "github_pr_checks"
  @max_files 50
  @max_total_bytes 524_288

  @tool_specs [
    %{
      "name" => @publish_tool,
      "description" => "Publish the current issue's text-file changes to its fixed GitHub branch and open or update a PR against main. This tool cannot merge PRs or target another repository.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["title", "body", "changes"],
        "properties" => %{
          "title" => %{"type" => "string", "description" => "Concise pull request title."},
          "body" => %{"type" => "string", "description" => "Pull request summary and validation performed."},
          "changes" => %{
            "type" => "array",
            "description" => "Complete final UTF-8 contents for changed files; use null content to delete a file.",
            "minItems" => 1,
            "maxItems" => @max_files,
            "items" => %{
              "type" => "object",
              "additionalProperties" => false,
              "required" => ["path", "content"],
              "properties" => %{
                "path" => %{"type" => "string"},
                "content" => %{"type" => ["string", "null"]}
              }
            }
          }
        }
      }
    },
    %{
      "name" => @checks_tool,
      "description" => "Read the current GitHub pull request and CI checks for this issue's fixed branch. This tool cannot change or merge anything.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{}
      }
    }
  ]

  @spec tool_specs() :: [map()]
  def tool_specs, do: @tool_specs

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(@publish_tool, arguments, opts), do: publish_pull_request(arguments, opts)
  def execute(@checks_tool, _arguments, opts), do: pull_request_checks(opts)
  def execute(tool, _arguments, _opts), do: failure(%{message: "Unsupported tool: #{inspect(tool)}"})

  defp publish_pull_request(arguments, opts) do
    with {:ok, issue_identifier} <- issue_identifier(opts),
         {:ok, title, body, changes} <- normalize_publish_arguments(arguments),
         {:ok, tracker_settings} <- tracker_settings(opts),
         :ok <- Client.validate_settings(tracker_settings),
         {:ok, branch, parent_sha, base_tree, branch_exists?} <- branch_base(issue_identifier, opts),
         {:ok, tree_sha} <- create_tree(base_tree, changes, tracker_settings, opts),
         {:ok, commit_sha} <- create_commit(issue_identifier, title, tree_sha, parent_sha, tracker_settings, opts),
         :ok <- update_branch(branch, commit_sha, branch_exists?, tracker_settings, opts),
         {:ok, pull_request} <- open_or_update_pull_request(branch, title, body, tracker_settings, opts) do
      success(%{
        repository: @repository,
        branch: branch,
        pull_request: pull_request,
        commit: commit_sha
      })
    else
      {:error, reason} -> failure(error_payload(reason))
    end
  end

  defp pull_request_checks(opts) do
    with {:ok, issue_identifier} <- issue_identifier(opts),
         {:ok, tracker_settings} <- tracker_settings(opts),
         :ok <- Client.validate_settings(tracker_settings),
         {:ok, branch} <- issue_branch(issue_identifier),
         {:ok, pull_request} <- find_open_pull_request(branch, tracker_settings, opts) do
      checks_result(branch, pull_request, tracker_settings, opts)
    else
      {:error, :pull_request_not_found} ->
        success(%{repository: @repository, branch: branch_for_issue(opts), pull_request: nil, checks: []})

      {:error, reason} ->
        failure(error_payload(reason))
    end
  end

  defp checks_result(branch, nil, _tracker_settings, _opts) do
    success(%{repository: @repository, branch: branch, pull_request: nil, checks: []})
  end

  defp checks_result(branch, pull_request, tracker_settings, opts) do
    with {:ok, checks} <- checks_for_pull_request(pull_request, tracker_settings, opts) do
      success(%{
        repository: @repository,
        branch: branch,
        pull_request: Map.take(pull_request, ["number", "html_url", "state", "draft", "head", "base"]),
        checks: checks
      })
    end
  end

  defp branch_base(issue_identifier, opts) do
    with {:ok, branch} <- issue_branch(issue_identifier),
         {:ok, tracker_settings} <- tracker_settings(opts),
         {:ok, branch_ref} <- api_request("GET", ref_path(branch), nil, tracker_settings, opts, [200, 404]) do
      branch_base_from_ref(branch_ref, branch, tracker_settings, opts)
    end
  end

  defp branch_base_from_ref(%{status: 200, body: %{"object" => %{"sha" => parent_sha}}}, branch, tracker_settings, opts) do
    case api_body("GET", "/repos/#{@repository}/git/commits/#{parent_sha}", nil, tracker_settings, opts) do
      {:ok, %{"tree" => %{"sha" => tree_sha}}} -> {:ok, branch, parent_sha, tree_sha, true}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_github_commit}
    end
  end

  defp branch_base_from_ref(%{status: 404}, branch, tracker_settings, opts) do
    with {:ok, %{"object" => %{"sha" => parent_sha}}} <-
           api_body("GET", ref_path(@base_branch), nil, tracker_settings, opts),
         {:ok, %{"tree" => %{"sha" => tree_sha}}} <-
           api_body("GET", "/repos/#{@repository}/git/commits/#{parent_sha}", nil, tracker_settings, opts) do
      {:ok, branch, parent_sha, tree_sha, false}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_github_base_commit}
    end
  end

  defp branch_base_from_ref(_branch_ref, _branch, _tracker_settings, _opts), do: {:error, :invalid_github_branch_ref}

  defp create_tree(base_tree, changes, tracker_settings, opts) do
    tree =
      Enum.map(changes, fn
        %{path: path, content: nil} -> %{"path" => path, "mode" => "100644", "type" => "blob", "sha" => nil}
        %{path: path, content: content} -> %{"path" => path, "mode" => "100644", "type" => "blob", "content" => content}
      end)

    case api_body(
           "POST",
           "/repos/#{@repository}/git/trees",
           %{"base_tree" => base_tree, "tree" => tree},
           tracker_settings,
           opts,
           [201]
         ) do
      {:ok, %{"sha" => tree_sha}} -> {:ok, tree_sha}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_github_tree}
    end
  end

  defp create_commit(issue_identifier, title, tree_sha, parent_sha, tracker_settings, opts) do
    message = "#{issue_identifier}: #{title}"

    case api_body(
           "POST",
           "/repos/#{@repository}/git/commits",
           %{"message" => message, "tree" => tree_sha, "parents" => [parent_sha]},
           tracker_settings,
           opts,
           [201]
         ) do
      {:ok, %{"sha" => commit_sha}} -> {:ok, commit_sha}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_github_commit}
    end
  end

  defp update_branch(branch, commit_sha, branch_exists?, tracker_settings, opts) do
    if branch_exists? do
      case api_request("PATCH", ref_path(branch), %{"sha" => commit_sha, "force" => false}, tracker_settings, opts, [200]) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      case api_request(
             "POST",
             "/repos/#{@repository}/git/refs",
             %{"ref" => "refs/heads/#{branch}", "sha" => commit_sha},
             tracker_settings,
             opts,
             [201]
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp open_or_update_pull_request(branch, title, body, tracker_settings, opts) do
    with {:ok, existing} <- find_open_pull_request(branch, tracker_settings, opts) do
      case existing do
        nil ->
          api_body(
            "POST",
            "/repos/#{@repository}/pulls",
            %{"title" => title, "body" => body, "head" => branch, "base" => @base_branch, "draft" => false},
            tracker_settings,
            opts,
            [201]
          )

        pull_request ->
          api_body(
            "PATCH",
            "/repos/#{@repository}/pulls/#{pull_request["number"]}",
            %{"title" => title, "body" => body},
            tracker_settings,
            opts
          )
      end
    end
  end

  defp find_open_pull_request(branch, tracker_settings, opts) do
    params = %{"head" => "Mesrine67:#{branch}", "base" => @base_branch, "state" => "open"}

    with {:ok, response} <- api_request("GET", "/repos/#{@repository}/pulls", nil, tracker_settings, opts, [200], params),
         pulls when is_list(pulls) <- response.body do
      case pulls do
        [pull | _] when is_map(pull) -> {:ok, pull}
        [] -> {:ok, nil}
        _ -> {:error, :invalid_github_pull_request_list}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_github_pull_request_list}
    end
  end

  defp checks_for_pull_request(%{"head" => %{"sha" => sha}}, tracker_settings, opts) do
    with {:ok, checks} when is_map(checks) <-
           api_body(
             "GET",
             "/repos/#{@repository}/commits/#{sha}/check-runs",
             nil,
             tracker_settings,
             opts,
             [200],
             anonymous: true
           ),
         check_runs when is_list(check_runs) <- Map.get(checks, "check_runs", []),
         {:ok, statuses} when is_map(statuses) <-
           api_body(
             "GET",
             "/repos/#{@repository}/commits/#{sha}/status",
             nil,
             tracker_settings,
             opts,
             [200],
             anonymous: true
           ) do
      check_runs = Enum.map(check_runs, fn check -> Map.take(check, ["name", "status", "conclusion", "html_url"]) end)
      {:ok, %{check_runs: check_runs, combined_status: Map.take(statuses, ["state", "total_count", "statuses"])}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_github_checks}
    end
  end

  defp checks_for_pull_request(_pull_request, _tracker_settings, _opts), do: {:error, :invalid_github_pull_request}

  defp normalize_publish_arguments(arguments) when is_map(arguments) do
    title = Map.get(arguments, "title")
    body = Map.get(arguments, "body")

    with true <- present_string?(title) || {:error, :invalid_pull_request_title},
         true <- present_string?(body) || {:error, :invalid_pull_request_body},
         {:ok, changes} <- normalize_changes(Map.get(arguments, "changes")) do
      {:ok, String.trim(title), body, changes}
    end
  end

  defp normalize_publish_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_changes(changes) when is_list(changes) and length(changes) in 1..@max_files do
    normalized = Enum.map(changes, &normalize_change/1)

    with true <- Enum.all?(normalized, &match?({:ok, _}, &1)) || {:error, :invalid_change},
         values <- Enum.map(normalized, fn {:ok, change} -> change end),
         true <- length(Enum.uniq_by(values, & &1.path)) == length(values) || {:error, :duplicate_change_path},
         total_bytes <- Enum.reduce(values, 0, fn %{content: content}, total -> total + byte_size(content || "") end),
         true <- total_bytes <= @max_total_bytes || {:error, :changes_too_large} do
      {:ok, values}
    end
  end

  defp normalize_changes(_changes), do: {:error, :invalid_changes}

  defp normalize_change(%{"path" => path, "content" => content}) when is_binary(path) and (is_binary(content) or is_nil(content)) do
    path_segments = String.split(path, "/")

    if safe_path?(path, path_segments) and not sensitive_path?(path_segments) and not workflow_path?(path_segments) do
      {:ok, %{path: path, content: content}}
    else
      {:error, :invalid_change_path}
    end
  end

  defp normalize_change(_change), do: {:error, :invalid_change}

  defp safe_path?(path, segments) do
    path != "" and not String.starts_with?(path, "/") and not String.contains?(path, ["\\", <<0>>]) and
      Enum.all?(segments, &(&1 not in ["", ".", "..", ".git", "node_modules", "target", "dist"]))
  end

  defp sensitive_path?(segments) do
    filename = segments |> List.last() |> String.downcase()

    String.starts_with?(filename, [".env", ".npmrc", ".pypirc"]) or
      String.starts_with?(filename, "id_") or
      String.ends_with?(filename, [".pem", ".p12", ".key"])
  end

  defp workflow_path?([".github", "workflows" | _segments]), do: true
  defp workflow_path?(_segments), do: false

  defp issue_branch(issue_identifier) when is_binary(issue_identifier) do
    if Regex.match?(~r/^[A-Z][A-Z0-9]*-[0-9]+$/, issue_identifier) do
      {:ok, "symphony/#{issue_identifier}"}
    else
      {:error, :invalid_issue_identifier}
    end
  end

  defp issue_identifier(opts) do
    case Keyword.get(opts, :issue) do
      %{identifier: identifier} when is_binary(identifier) -> {:ok, identifier}
      %{"identifier" => identifier} when is_binary(identifier) -> {:ok, identifier}
      _ -> {:error, :missing_issue_identifier}
    end
  end

  defp branch_for_issue(opts) do
    case issue_identifier(opts) do
      {:ok, identifier} ->
        case issue_branch(identifier) do
          {:ok, branch} -> branch
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp tracker_settings(opts) do
    case Keyword.get(opts, :tracker_settings) do
      %{kind: "linear", provider: provider} = settings when is_map(provider) ->
        if provider["repo"] == @repository, do: {:ok, settings}, else: {:error, :repository_scope_mismatch}

      _ ->
        {:error, :missing_tracker_settings}
    end
  end

  defp api_body(method, path, body, tracker_settings, opts, accepted_statuses \\ [200], request_options \\ []) do
    with {:ok, %{body: response_body}} <-
           api_request(method, path, body, tracker_settings, opts, accepted_statuses, %{}, request_options) do
      {:ok, response_body}
    end
  end

  defp api_request(method, path, body, tracker_settings, opts, accepted_statuses, params \\ %{}, request_options \\ []) do
    github_client = Keyword.get(opts, :github_client, &Client.request/5)
    client_options = Keyword.put(request_options, :tracker_settings, tracker_settings)

    case github_client.(method, path, params, body, client_options) do
      {:ok, %{status: status, body: response_body} = response} when is_integer(status) ->
        if status in accepted_statuses do
          {:ok, Map.put(response, :body, response_body)}
        else
          {:error, {:github_api_status, status}}
        end

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :github_unknown_payload}
    end
  end

  defp ref_path(branch) do
    encoded_branch = URI.encode(branch, &URI.char_unreserved?/1)
    "/repos/#{@repository}/git/ref/heads/#{encoded_branch}"
  end

  defp success(payload), do: dynamic_response(true, payload)
  defp failure(payload), do: dynamic_response(false, %{error: payload})

  defp dynamic_response(success?, payload) do
    output = Jason.encode!(payload, pretty: true)

    %{
      "success" => success?,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp error_payload({:github_api_status, status}), do: %{message: "GitHub rejected the scoped request.", status: status}
  defp error_payload(:invalid_issue_identifier), do: %{message: "The Linear issue identifier is invalid; no GitHub request was made."}
  defp error_payload(:repository_scope_mismatch), do: %{message: "GitHub publishing is restricted to #{@repository}."}
  defp error_payload(reason), do: %{message: "GitHub publication failed.", reason: inspect(reason)}

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false
end
