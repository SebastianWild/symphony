defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Tracker.ObsidianKanban

  @linear_graphql_tool "linear_graphql"
  @obsidian_kanban_tool "obsidian_kanban"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }
  @obsidian_kanban_description """
  Read and update the configured Obsidian Kanban card and linked note workpad.
  """
  @obsidian_kanban_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["action"],
    "properties" => %{
      "action" => %{
        "type" => "string",
        "enum" => ["read_current_issue", "read_issue", "update_state", "replace_workpad_section", "append_workpad_section"]
      },
      "issue_id" => %{
        "type" => ["string", "null"],
        "description" => "Obsidian wikilink target. Defaults to the current issue for read_current_issue."
      },
      "state" => %{
        "type" => ["string", "null"],
        "description" => "Target Kanban column for update_state."
      },
      "body" => %{
        "type" => ["string", "null"],
        "description" => "Markdown body for replace_workpad_section or append_workpad_section."
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    kind = tracker_kind()

    case {tool, kind} do
      {@linear_graphql_tool, "linear"} ->
        execute_linear_graphql(arguments, opts)

      {@obsidian_kanban_tool, "obsidian_kanban"} ->
        execute_obsidian_kanban(arguments, opts)

      {other, _kind} ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    case tracker_kind() do
      "obsidian_kanban" ->
        [
          %{
            "name" => @obsidian_kanban_tool,
            "description" => @obsidian_kanban_description,
            "inputSchema" => @obsidian_kanban_input_schema
          }
        ]

      "linear" ->
        [
          %{
            "name" => @linear_graphql_tool,
            "description" => @linear_graphql_description,
            "inputSchema" => @linear_graphql_input_schema
          }
        ]

      _ ->
        []
    end
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_obsidian_kanban(arguments, opts) when is_map(arguments) do
    adapter = Keyword.get(opts, :obsidian_kanban_adapter, ObsidianKanban)

    with {:ok, action} <- normalize_action(arguments),
         {:ok, payload} <- run_obsidian_action(adapter, action, arguments, opts) do
      dynamic_tool_response(true, encode_payload(payload))
    else
      {:error, reason} ->
        failure_response(obsidian_error_payload(reason))
    end
  end

  defp execute_obsidian_kanban(_arguments, _opts), do: failure_response(obsidian_error_payload(:invalid_arguments))

  defp normalize_action(arguments) do
    case Map.get(arguments, "action") || Map.get(arguments, :action) do
      action
      when action in [
             "read_current_issue",
             "read_issue",
             "update_state",
             "replace_workpad_section",
             "append_workpad_section"
           ] ->
        {:ok, action}

      _ ->
        {:error, :missing_obsidian_action}
    end
  end

  defp run_obsidian_action(adapter, "read_current_issue", arguments, opts) do
    with {:ok, issue_id} <- issue_id(arguments, opts),
         {:ok, issue} <- adapter.read_issue(issue_id) do
      {:ok, %{"issue" => issue_payload(issue)}}
    end
  end

  defp run_obsidian_action(adapter, "read_issue", arguments, opts) do
    with {:ok, issue_id} <- issue_id(arguments, opts),
         {:ok, issue} <- adapter.read_issue(issue_id) do
      {:ok, %{"issue" => issue_payload(issue)}}
    end
  end

  defp run_obsidian_action(adapter, "update_state", arguments, opts) do
    with {:ok, issue_id} <- issue_id(arguments, opts),
         {:ok, state} <- required_string(arguments, "state", :missing_state),
         :ok <- adapter.update_issue_state(issue_id, state),
         {:ok, issue} <- adapter.read_issue(issue_id) do
      {:ok, %{"issue" => issue_payload(issue)}}
    end
  end

  defp run_obsidian_action(adapter, "replace_workpad_section", arguments, opts) do
    with {:ok, issue_id} <- issue_id(arguments, opts),
         {:ok, body} <- required_string(arguments, "body", :missing_body),
         :ok <- adapter.replace_note_workpad_section(issue_id, body) do
      {:ok, %{"issue_id" => issue_id, "updated" => true}}
    end
  end

  defp run_obsidian_action(adapter, "append_workpad_section", arguments, opts) do
    with {:ok, issue_id} <- issue_id(arguments, opts),
         {:ok, body} <- required_string(arguments, "body", :missing_body),
         :ok <- adapter.append_note_workpad_section(issue_id, body) do
      {:ok, %{"issue_id" => issue_id, "updated" => true}}
    end
  end

  defp issue_id(arguments, opts) do
    case optional_string(arguments, "issue_id") do
      value when is_binary(value) ->
        {:ok, value}

      _ ->
        case Keyword.get(opts, :issue) do
          %{id: id} when is_binary(id) -> {:ok, id}
          _ -> {:error, :missing_issue_id}
        end
    end
  end

  defp required_string(arguments, field, error) do
    case optional_string(arguments, field) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, error}
    end
  end

  defp optional_string(arguments, field) do
    case Map.get(arguments, field) || Map.get(arguments, String.to_atom(field)) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp issue_payload(issue) when is_map(issue) do
    issue
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {to_string(key), payload_value(value)} end)
  end

  defp payload_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp payload_value(value), do: value

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp obsidian_error_payload(reason) do
    message =
      case reason do
        :invalid_arguments ->
          "`obsidian_kanban` expects an object with an `action` string."

        :missing_obsidian_action ->
          "`obsidian_kanban.action` is required and must be one of the supported actions."

        :missing_issue_id ->
          "`obsidian_kanban` requires `issue_id` unless the current issue is available."

        :missing_state ->
          "`obsidian_kanban.update_state` requires a non-empty `state` string."

        :missing_body ->
          "`obsidian_kanban` workpad updates require a non-empty `body` string."

        _ ->
          "Obsidian Kanban tool execution failed."
      end

    payload = %{"error" => %{"message" => message}}

    if message == "Obsidian Kanban tool execution failed." do
      put_in(payload, ["error", "reason"], inspect(reason))
    else
      payload
    end
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end

  defp tracker_kind do
    Config.settings!().tracker.kind
  rescue
    _ -> "linear"
  end
end
