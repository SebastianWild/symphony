---
tracker:
  kind: obsidian_kanban
  board_path: ~/Obsidian/Work/Kanban.md
  required_tags:
    - automated-setups
  active_states:
    - Todo
    - In Progress
    - Rework
    - Merging
  terminal_states:
    - Done
    - Canceled
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces/automated-setups
hooks:
  before_poll: |
    ob sync --path ~/Obsidian/Work
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

You are working from the linked Obsidian note for `{{ issue.identifier }}`.

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
Note path: {{ issue.url }}

Linked note:
{% if issue.description %}
{{ issue.description }}
{% else %}
No note body was found.
{% endif %}

Instructions:

1. Use the `obsidian_kanban` tool as the tracker interface.
2. For `Todo`, move the card to `In Progress` before active work.
3. Treat the linked note's `## Codex Workpad` section as the durable workpad. Replace or append that section as progress changes.
4. Move completed work to `Human Review` when ready for human review, `Rework` when reviewer changes are needed, `Merging` when approved, and `Done` only after merge/completion.
5. Do not use Linear MCP or `linear_graphql` in this workflow.
