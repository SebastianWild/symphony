defmodule SymphonyElixir.Tracker.ObsidianKanban do
  @moduledoc """
  Obsidian Kanban markdown-file tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @workpad_heading "## Codex Workpad"
  @card_pattern ~r/^(\s*-\s+\[)( |x|X)(\]\s+\[\[([^\]]+)\]\])(.*)$/

  defmodule Board do
    @moduledoc false
    defstruct [:path, :prefix, :suffix, lanes: []]

    @type t :: %__MODULE__{
            path: Path.t(),
            prefix: [String.t()],
            suffix: [String.t()],
            lanes: [SymphonyElixir.Tracker.ObsidianKanban.Lane.t()]
          }
  end

  defmodule Lane do
    @moduledoc false
    defstruct [:name, :heading, body: []]

    @type t :: %__MODULE__{
            name: String.t(),
            heading: String.t(),
            body: [String.t()]
          }
  end

  @impl true
  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    fetch_issues_by_states(Config.settings!().tracker.active_states)
  end

  @impl true
  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    wanted_states = state_names |> Enum.map(&normalize/1) |> MapSet.new()

    with {:ok, board} <- load_board(),
         {:ok, issues} <- safe_issues_from_board(board) do
      {:ok,
       issues
       |> Enum.filter(fn %Issue{state: state} -> MapSet.member?(wanted_states, normalize(state)) end)}
    end
  end

  @impl true
  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    with {:ok, board} <- load_board(),
         {:ok, issues} <- safe_issues_from_board(board) do
      {:ok,
       issues
       |> Enum.filter(fn %Issue{id: id} -> MapSet.member?(wanted_ids, id) end)}
    end
  end

  @impl true
  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    append_note_workpad_section(issue_id, body)
  end

  @impl true
  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, content, stat} <- read_file_with_stat(board_path()),
         {:ok, board} <- parse_board(content, board_path()),
         {:ok, updated_board} <- move_card(board, issue_id, state_name),
         :ok <- write_file_if_unchanged(board.path, render_board(updated_board), stat) do
      :ok
    end
  end

  @spec read_issue(String.t()) :: {:ok, Issue.t()} | {:error, term()}
  def read_issue(issue_id) when is_binary(issue_id) do
    case fetch_issue_states_by_ids([issue_id]) do
      {:ok, [%Issue{} = issue | _]} -> {:ok, issue}
      {:ok, []} -> {:error, :issue_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec replace_note_workpad_section(String.t(), String.t()) :: :ok | {:error, term()}
  def replace_note_workpad_section(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    update_note_workpad_section(issue_id, body, :replace)
  end

  @spec append_note_workpad_section(String.t(), String.t()) :: :ok | {:error, term()}
  def append_note_workpad_section(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    update_note_workpad_section(issue_id, body, :append)
  end

  @doc false
  @spec parse_board_for_test(String.t(), Path.t()) :: {:ok, Board.t()}
  def parse_board_for_test(content, path), do: parse_board(content, path)

  @doc false
  @spec render_board_for_test(Board.t()) :: String.t()
  def render_board_for_test(%Board{} = board), do: render_board(board)

  @doc false
  @spec issues_from_board_for_test(Board.t()) :: [Issue.t()]
  def issues_from_board_for_test(%Board{} = board), do: issues_from_board(board)

  @doc false
  @spec move_card_for_test(Board.t(), String.t(), String.t()) :: {:ok, Board.t()} | {:error, term()}
  def move_card_for_test(%Board{} = board, issue_id, state_name), do: move_card(board, issue_id, state_name)

  defp load_board do
    with {:ok, content, _stat} <- read_file_with_stat(board_path()) do
      parse_board(content, board_path())
    end
  end

  defp board_path do
    Config.settings!().tracker.board_path
  end

  defp read_file_with_stat(path) when is_binary(path) do
    with {:ok, stat} <- File.stat(path),
         {:ok, content} <- File.read(path) do
      {:ok, content, stat_signature(stat)}
    else
      {:error, reason} -> {:error, {:file_read_failed, path, reason}}
    end
  end

  defp parse_board(content, path) when is_binary(content) and is_binary(path) do
    lines = split_lines(content)
    {board_lines, suffix} = split_settings_suffix(lines)
    {prefix, lane_lines} = Enum.split_while(board_lines, &(lane_heading_name(&1) == nil))

    {:ok,
     %Board{
       path: path,
       prefix: prefix,
       lanes: parse_lanes(lane_lines, []),
       suffix: suffix
     }}
  end

  defp split_lines(""), do: []
  defp split_lines(content), do: String.split(content, ~r/(?<=\n)/, trim: false)

  defp split_settings_suffix(lines) do
    case Enum.find_index(lines, &(String.trim(&1) == "%% kanban:settings")) do
      nil -> {lines, []}
      index -> Enum.split(lines, index)
    end
  end

  defp parse_lanes([], acc), do: Enum.reverse(acc)

  defp parse_lanes([heading | rest], acc) do
    case lane_heading_name(heading) do
      nil ->
        parse_lanes(rest, acc)

      name ->
        {body, remaining} = Enum.split_while(rest, &(lane_heading_name(&1) == nil))
        parse_lanes(remaining, [%Lane{name: name, heading: heading, body: body} | acc])
    end
  end

  defp lane_heading_name(line) do
    case Regex.run(~r/^##\s+(.+?)\s*(?:\r?\n)?$/, line) do
      [_match, name] -> String.trim(name)
      _ -> nil
    end
  end

  defp issues_from_board(%Board{} = board) do
    board.lanes
    |> Enum.flat_map(&issues_from_lane(board, &1))
    |> reject_duplicate_issue_ids()
  end

  defp safe_issues_from_board(%Board{} = board) do
    {:ok, issues_from_board(board)}
  rescue
    error in [ArgumentError] ->
      {:error, {:invalid_obsidian_board, Exception.message(error)}}
  end

  defp issues_from_lane(%Board{} = board, %Lane{} = lane) do
    lane.body
    |> Enum.flat_map(fn line ->
      case parse_card_line(line) do
        {:ok, card} ->
          [issue_from_card(board, lane.name, card)]

        :error ->
          []
      end
    end)
  end

  defp issue_from_card(%Board{} = board, state, card) do
    note = read_note(board.path, card.id)
    labels = labels_from_text([card.trailing_text, note.description])

    %Issue{
      id: card.id,
      identifier: card.display,
      title: card.display,
      description: note.description,
      priority: nil,
      state: state,
      branch_name: nil,
      url: note.path,
      assignee_id: nil,
      blocked_by: [],
      labels: labels,
      assigned_to_worker: true,
      created_at: nil,
      updated_at: note.updated_at
    }
  end

  defp reject_duplicate_issue_ids(issues) do
    Enum.reduce(issues, {[], MapSet.new(), MapSet.new()}, fn %Issue{id: id} = issue, {acc, seen, dupes} ->
      if MapSet.member?(seen, id) do
        {acc, seen, MapSet.put(dupes, id)}
      else
        {[issue | acc], MapSet.put(seen, id), dupes}
      end
    end)
    |> then(fn {issues, _seen, dupes} ->
      if MapSet.size(dupes) == 0 do
        Enum.reverse(issues)
      else
        raise ArgumentError, "duplicate Obsidian Kanban wikilink IDs: #{inspect(MapSet.to_list(dupes))}"
      end
    end)
  end

  defp parse_card_line(line) do
    case Regex.run(@card_pattern, line) do
      [_match, _prefix, checked, _link_text, raw_link, trailing_text] ->
        {id, display} = parse_wikilink(raw_link)

        {:ok,
         %{
           id: id,
           display: display,
           checked?: String.downcase(checked) == "x",
           trailing_text: trailing_text,
           line: line
         }}

      _ ->
        :error
    end
  end

  defp parse_wikilink(raw_link) do
    [target, alias_name] =
      case String.split(raw_link, "|", parts: 2) do
        [target] -> [target, nil]
        [target, alias_name] -> [target, alias_name]
      end

    id = String.trim(target)
    display = String.trim(alias_name || Path.basename(id))
    {id, display}
  end

  defp read_note(board_path, issue_id) do
    case note_path(board_path, issue_id) do
      {:ok, path} ->
        case File.read(path) do
          {:ok, content} ->
            %{
              path: path,
              description: content,
              updated_at: file_updated_at(path),
              labels: labels_from_text([content])
            }

          {:error, _reason} ->
            %{path: path, description: nil, updated_at: nil, labels: []}
        end

      {:error, _reason} ->
        %{path: nil, description: nil, updated_at: nil, labels: []}
    end
  end

  defp labels_from_text(texts) do
    texts
    |> Enum.flat_map(fn
      text when is_binary(text) ->
        regex_tags(text) ++ frontmatter_tags(text)

      _ ->
        []
    end)
    |> Enum.map(&normalize_label/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp regex_tags(text) do
    ~r/(?:^|\s)#([A-Za-z0-9_\/-]+)/
    |> Regex.scan(text)
    |> Enum.map(fn [_match, tag] -> tag end)
  end

  defp frontmatter_tags(text) do
    case split_frontmatter(text) do
      {:ok, yaml} ->
        case YamlElixir.read_from_string(yaml) do
          {:ok, %{"tags" => tags}} -> flatten_tags(tags)
          {:ok, %{tags: tags}} -> flatten_tags(tags)
          _ -> []
        end

      :error ->
        []
    end
  end

  defp split_frontmatter(text) do
    case String.split(text, ~r/\R/, trim: false) do
      ["---" | rest] ->
        {frontmatter, remaining} = Enum.split_while(rest, &(&1 != "---"))

        case remaining do
          ["---" | _] -> {:ok, Enum.join(frontmatter, "\n")}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp flatten_tags(tags) when is_list(tags), do: Enum.flat_map(tags, &flatten_tags/1)
  defp flatten_tags(tag) when is_binary(tag), do: [tag]
  defp flatten_tags(_tag), do: []

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.trim_leading("#")
    |> String.downcase()
  end

  defp file_updated_at(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> DateTime.from_unix!(mtime)
      _ -> nil
    end
  end

  defp move_card(%Board{} = board, issue_id, state_name) do
    with {:ok, matches} <- card_matches(board, issue_id),
         {:ok, target_index} <- lane_index(board, state_name) do
      case matches do
        [{source_index, line_index, card}] ->
          {:ok, move_card_between_lanes(board, source_index, line_index, card, target_index, state_name)}

        [] ->
          {:error, :issue_not_found}

        _ ->
          {:error, {:duplicate_obsidian_wikilink_id, issue_id}}
      end
    end
  end

  defp card_matches(%Board{} = board, issue_id) do
    matches =
      board.lanes
      |> Enum.with_index()
      |> Enum.flat_map(fn {%Lane{} = lane, lane_index} ->
        lane.body
        |> Enum.with_index()
        |> Enum.flat_map(fn {line, line_index} ->
          case parse_card_line(line) do
            {:ok, %{id: ^issue_id} = card} -> [{lane_index, line_index, card}]
            _ -> []
          end
        end)
      end)

    {:ok, matches}
  end

  defp lane_index(%Board{} = board, state_name) do
    normalized = normalize(state_name)

    case Enum.find_index(board.lanes, &(normalize(&1.name) == normalized)) do
      nil -> {:error, {:missing_target_lane, state_name}}
      index -> {:ok, index}
    end
  end

  defp move_card_between_lanes(%Board{} = board, source_index, line_index, card, target_index, state_name) do
    updated_line = set_card_checked(card.line, terminal_state?(state_name))

    lanes =
      if source_index == target_index do
        List.update_at(board.lanes, source_index, fn %Lane{} = lane ->
          %{lane | body: List.replace_at(lane.body, line_index, updated_line)}
        end)
      else
        board.lanes
        |> List.update_at(source_index, fn %Lane{} = lane ->
          %{lane | body: List.delete_at(lane.body, line_index)}
        end)
        |> List.update_at(target_index, fn %Lane{} = lane ->
          %{lane | body: insert_card_line(lane.body, updated_line)}
        end)
      end

    %{board | lanes: lanes}
  end

  defp terminal_state?(state_name) do
    normalized = normalize(state_name)

    Config.settings!().tracker.terminal_states
    |> Enum.any?(&(normalize(&1) == normalized))
  end

  defp set_card_checked(line, true), do: Regex.replace(@card_pattern, line, "\\1x\\3\\5", global: false)
  defp set_card_checked(line, false), do: Regex.replace(@card_pattern, line, "\\1 \\3\\5", global: false)

  defp insert_card_line(body, line) do
    {trailing_blanks, reversed_content} =
      body
      |> Enum.reverse()
      |> Enum.split_while(&(String.trim(&1) == ""))

    Enum.reverse(reversed_content) ++ [ensure_newline(line)] ++ Enum.reverse(trailing_blanks)
  end

  defp ensure_newline(line) do
    if String.ends_with?(line, "\n"), do: line, else: line <> "\n"
  end

  defp render_board(%Board{} = board) do
    [
      board.prefix,
      Enum.flat_map(board.lanes, fn %Lane{} = lane -> [lane.heading | lane.body] end),
      board.suffix
    ]
    |> List.flatten()
    |> Enum.join("")
  end

  defp update_note_workpad_section(issue_id, body, mode) do
    with {:ok, board} <- load_board(),
         {:ok, %Issue{} = issue} <- read_issue(issue_id),
         {:ok, path} <- note_path(board.path, issue.id),
         :ok <- ensure_note_inside_board_dir(board.path, path),
         {:ok, content, stat} <- read_optional_file_with_stat(path),
         updated <- rewrite_workpad_section(content, body, mode),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- write_file_if_unchanged(path, updated, stat) do
      :ok
    end
  end

  defp read_optional_file_with_stat(path) do
    case File.stat(path) do
      {:ok, stat} ->
        with {:ok, content} <- File.read(path) do
          {:ok, content, stat_signature(stat)}
        end

      {:error, :enoent} ->
        {:ok, "", nil}

      {:error, reason} ->
        {:error, {:file_read_failed, path, reason}}
    end
  end

  defp rewrite_workpad_section(content, body, :replace) do
    case split_workpad_section(content) do
      {:ok, before_section, _existing, after_section} ->
        before_section <> workpad_section(body) <> after_section

      :error ->
        append_section(content, body)
    end
  end

  defp rewrite_workpad_section(content, body, :append) do
    case split_workpad_section(content) do
      {:ok, before_section, existing, after_section} ->
        before_section <> existing <> "\n" <> String.trim_trailing(body) <> "\n" <> after_section

      :error ->
        append_section(content, body)
    end
  end

  defp split_workpad_section(content) do
    lines = split_lines(content)

    case Enum.find_index(lines, &(String.trim(&1) == @workpad_heading)) do
      nil ->
        :error

      start_index ->
        {before_section, section_and_after} = Enum.split(lines, start_index)
        {section, after_section} = split_section_and_after(section_and_after)
        {:ok, Enum.join(before_section, ""), Enum.join(section, ""), Enum.join(after_section, "")}
    end
  end

  defp split_section_and_after([]), do: {[], []}

  defp split_section_and_after([heading | rest]) do
    {body, after_section} = Enum.split_while(rest, &(not same_or_higher_heading?(&1)))
    {[heading | body], after_section}
  end

  defp same_or_higher_heading?(line), do: Regex.match?(~r/^\#{1,2}\s+/, line)

  defp append_section("", body), do: workpad_section(body)
  defp append_section(content, body), do: String.trim_trailing(content) <> "\n\n" <> workpad_section(body)

  defp workpad_section(body) do
    @workpad_heading <> "\n\n" <> String.trim_trailing(body) <> "\n"
  end

  defp note_path(board_path, issue_id) do
    board_dir = Path.dirname(board_path)
    target = String.trim(issue_id)

    cond do
      target == "" ->
        {:error, :blank_note_target}

      Path.type(target) == :absolute ->
        {:error, :absolute_note_target}

      true ->
        target_path = if Path.extname(target) == "", do: target <> ".md", else: target
        path = Path.expand(Path.join(board_dir, target_path))

        with :ok <- ensure_note_inside_board_dir(board_path, path) do
          {:ok, path}
        end
    end
  end

  defp ensure_note_inside_board_dir(board_path, note_path) do
    board_dir = Path.expand(Path.dirname(board_path))
    expanded_note = Path.expand(note_path)

    if String.starts_with?(expanded_note, board_dir <> "/") do
      :ok
    else
      {:error, {:note_outside_board_dir, expanded_note, board_dir}}
    end
  end

  defp write_file_if_unchanged(path, content, original_signature) do
    with :ok <- reject_if_changed(path, original_signature),
         :ok <- atomic_write(path, content) do
      :ok
    end
  end

  defp reject_if_changed(path, nil) do
    if File.exists?(path), do: {:error, {:stale_file, path}}, else: :ok
  end

  defp reject_if_changed(path, original_signature) do
    case File.stat(path) do
      {:ok, stat} ->
        current_signature = stat_signature(stat)

        if current_signature == original_signature do
          :ok
        else
          {:error, {:stale_file, path}}
        end

      {:error, reason} ->
        {:error, {:file_stat_failed, path, reason}}
    end
  end

  defp atomic_write(path, content) do
    tmp_path = Path.join(Path.dirname(path), ".#{Path.basename(path)}.symphony-#{System.unique_integer([:positive])}.tmp")

    with :ok <- File.write(tmp_path, content),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, {:file_write_failed, path, reason}}
    end
  end

  defp stat_signature(%File.Stat{mtime: mtime, size: size}), do: {mtime, size}

  defp normalize(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize(_value), do: ""
end
