defmodule SymphonyElixir.ObsidianKanbanTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Tracker.ObsidianKanban

  test "parses lanes, wikilink cards, aliases, tags, notes, and settings block" do
    test_root = tmp_dir("obsidian-parse")
    board_path = Path.join(test_root, "Kanban.md")
    note_path = Path.join(test_root, "Note One.md")
    nested_note_path = Path.join([test_root, "Folder", "Note Two.md"])

    File.mkdir_p!(Path.dirname(nested_note_path))
    File.write!(note_path, "---\ntags: [note-tag, backend]\n---\n\nBody #bodytag\n")
    File.write!(nested_note_path, "Nested note #nested\n")

    board = """
    ---
    kanban-plugin: board
    ---

    ## Todo
    - [ ] [[Note One|Alias One]] #cardtag keep this text
    - regular list item

    ## In Progress
    - [x] [[Folder/Note Two]]

    ## Empty

    %% kanban:settings
    {"kanban-plugin":"board"}

    ## Ignored
    - [ ] [[After Settings]]
    """

    assert {:ok, parsed} = ObsidianKanban.parse_board_for_test(board, board_path)
    assert Enum.map(parsed.lanes, & &1.name) == ["Todo", "In Progress", "Empty"]
    assert parsed.suffix |> Enum.join("") =~ "%% kanban:settings"

    issues = ObsidianKanban.issues_from_board_for_test(parsed)

    assert Enum.map(issues, & &1.id) == ["Note One", "Folder/Note Two"]

    assert %Issue{
             id: "Note One",
             identifier: "Alias One",
             title: "Alias One",
             state: "Todo",
             description: description,
             labels: labels,
             url: ^note_path
           } = hd(issues)

    assert description =~ "Body #bodytag"
    assert Enum.sort(labels) == ["backend", "bodytag", "cardtag", "note-tag"]

    assert Enum.at(issues, 1).identifier == "Note Two"
    assert Enum.at(issues, 1).labels == ["nested"]
  end

  test "moves cards between lanes and marks terminal-state cards checked" do
    test_root = tmp_dir("obsidian-move")
    board_path = Path.join(test_root, "Kanban.md")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "obsidian_kanban",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_board_path: board_path,
      tracker_active_states: ["Todo", "In Progress", "Rework", "Merging"],
      tracker_terminal_states: ["Done", "Canceled"]
    )

    board = """
    ---
    kanban-plugin: board
    ---

    ## Todo
    - [ ] [[Note One]] #keep
    - [ ] [[Note Two]]

    ## In Progress

    ## Done

    %% kanban:settings
    {"preserve":true}
    """

    assert {:ok, parsed} = ObsidianKanban.parse_board_for_test(board, board_path)
    assert {:ok, moved} = ObsidianKanban.move_card_for_test(parsed, "Note One", "In Progress")
    rendered = ObsidianKanban.render_board_for_test(moved)

    assert rendered =~ "## Todo\n- [ ] [[Note Two]]\n"
    assert rendered =~ "## In Progress\n- [ ] [[Note One]] #keep\n"
    assert rendered =~ ~s({"preserve":true})

    assert {:ok, done} = ObsidianKanban.move_card_for_test(moved, "Note One", "Done")
    rendered_done = ObsidianKanban.render_board_for_test(done)

    assert rendered_done =~ "## Done\n- [x] [[Note One]] #keep\n"
  end

  test "state moves fail cleanly on duplicate wikilinks and missing lanes" do
    test_root = tmp_dir("obsidian-errors")
    board_path = Path.join(test_root, "Kanban.md")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "obsidian_kanban",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_board_path: board_path,
      tracker_terminal_states: ["Done"]
    )

    board = """
    ## Todo
    - [ ] [[Same]]

    ## In Progress
    - [ ] [[Same]]
    """

    assert {:ok, parsed} = ObsidianKanban.parse_board_for_test(board, board_path)
    assert {:error, {:duplicate_obsidian_wikilink_id, "Same"}} = ObsidianKanban.move_card_for_test(parsed, "Same", "Todo")
    assert {:error, {:missing_target_lane, "Done"}} = ObsidianKanban.move_card_for_test(parsed, "Missing", "Done")
  end

  test "config validates Obsidian without Linear credentials and adapter returns tracker issues" do
    test_root = tmp_dir("obsidian-config")
    board_path = Path.join(test_root, "Kanban.md")

    File.write!(board_path, """
    ## Todo
    - [ ] [[First]]

    ## Done
    - [x] [[Finished]]
    """)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "obsidian_kanban",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_board_path: board_path,
      tracker_active_states: ["Todo"],
      tracker_terminal_states: ["Done"]
    )

    assert :ok = Config.validate!()
    assert Tracker.adapter() == ObsidianKanban
    assert {:ok, [%Issue{id: "First", state: "Todo"}]} = Tracker.fetch_candidate_issues()
    assert {:ok, [%Issue{id: "Finished", state: "Done"}]} = Tracker.fetch_issues_by_states(["Done"])
    assert {:ok, [%Issue{id: "First"}]} = Tracker.fetch_issue_states_by_ids(["First"])
  end

  test "required tags filter shared Obsidian boards by repo scope" do
    test_root = tmp_dir("obsidian-required-tags")
    board_path = Path.join(test_root, "Kanban.md")

    File.write!(Path.join(test_root, "Body Tagged.md"), "Body #automated-setups\n")
    File.write!(Path.join(test_root, "Frontmatter Tagged.md"), "---\ntags: [automated-setups]\n---\n\nBody\n")

    scoped_board = """
    ## Todo
    - [ ] [[Card Tagged]] #automated-setups
    - [ ] [[Body Tagged]]
    - [ ] [[Frontmatter Tagged]]
    - [ ] [[Wrong Repo]] #symphony
    - [ ] [[Untagged]]

    ## Done
    - [x] [[Finished]] #automated-setups
    - [x] [[Finished Untagged]]
    """

    File.write!(board_path, scoped_board)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "obsidian_kanban",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_board_path: board_path,
      tracker_required_tags: ["#Automated-Setups"],
      tracker_active_states: ["Todo"],
      tracker_terminal_states: ["Done"]
    )

    assert Config.settings!().tracker.required_tags == ["automated-setups"]

    assert {:ok, candidates} = Tracker.fetch_candidate_issues()
    assert Enum.map(candidates, & &1.id) == ["Card Tagged", "Body Tagged", "Frontmatter Tagged"]

    assert {:ok, [%Issue{id: "Finished"}]} = Tracker.fetch_issues_by_states(["Done"])
    assert {:ok, [%Issue{id: "Card Tagged"}]} = Tracker.fetch_issue_states_by_ids(["Card Tagged", "Untagged"])

    File.write!(board_path, String.replace(scoped_board, " #automated-setups", "", global: false))

    assert {:ok, []} = Tracker.fetch_issue_states_by_ids(["Card Tagged"])
  end

  test "obsidian_kanban write actions reject unscoped shared-board issues" do
    test_root = tmp_dir("obsidian-required-tags-writes")
    board_path = Path.join(test_root, "Kanban.md")
    unscoped_note_path = Path.join(test_root, "Unscoped.md")

    File.write!(board_path, """
    ## Todo
    - [ ] [[Scoped]] #automated-setups
    - [ ] [[Unscoped]]

    ## In Progress
    """)

    File.write!(unscoped_note_path, "# Unscoped\n\nDo not edit\n")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "obsidian_kanban",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_board_path: board_path,
      tracker_required_tags: ["automated-setups"],
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done"]
    )

    state =
      DynamicTool.execute("obsidian_kanban", %{
        "action" => "update_state",
        "issue_id" => "Unscoped",
        "state" => "In Progress"
      })

    assert state["success"] == false
    assert File.read!(board_path) =~ "## Todo\n- [ ] [[Scoped]] #automated-setups\n- [ ] [[Unscoped]]\n\n## In Progress\n"

    replace =
      DynamicTool.execute("obsidian_kanban", %{
        "action" => "replace_workpad_section",
        "issue_id" => "Unscoped",
        "body" => "- [ ] should not write"
      })

    assert replace["success"] == false
    refute File.read!(unscoped_note_path) =~ "## Codex Workpad"
  end

  test "obsidian_kanban tool is advertised only for Obsidian workflows and updates notes" do
    test_root = tmp_dir("obsidian-tool")
    board_path = Path.join(test_root, "Kanban.md")
    note_path = Path.join(test_root, "Tool Note.md")

    File.write!(board_path, """
    ## Todo
    - [ ] [[Tool Note]]

    ## In Progress
    """)

    File.write!(note_path, "# Tool Note\n\nOld body\n")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "obsidian_kanban",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_board_path: board_path,
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done"]
    )

    assert [%{"name" => "obsidian_kanban"}] = DynamicTool.tool_specs()

    read =
      DynamicTool.execute("obsidian_kanban", %{"action" => "read_current_issue"}, issue: %Issue{id: "Tool Note"})

    assert read["success"] == true
    assert get_in(Jason.decode!(read["output"]), ["issue", "id"]) == "Tool Note"

    replace =
      DynamicTool.execute("obsidian_kanban", %{
        "action" => "replace_workpad_section",
        "issue_id" => "Tool Note",
        "body" => "- [ ] validate"
      })

    assert replace["success"] == true
    assert File.read!(note_path) =~ "## Codex Workpad\n\n- [ ] validate\n"

    state =
      DynamicTool.execute("obsidian_kanban", %{
        "action" => "update_state",
        "issue_id" => "Tool Note",
        "state" => "In Progress"
      })

    assert state["success"] == true
    assert File.read!(board_path) =~ "## In Progress\n- [ ] [[Tool Note]]\n"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert [%{"name" => "linear_graphql"}] = DynamicTool.tool_specs()
  end

  defp tmp_dir(label) do
    path = Path.join(System.tmp_dir!(), "symphony-elixir-#{label}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
