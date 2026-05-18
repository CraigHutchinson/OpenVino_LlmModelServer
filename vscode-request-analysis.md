# VS Code Copilot Request Body Analysis

Captured from `vscode_copilot_request_body.json` — a single "hi" sent from VS Code Insiders in
**Ask mode** with the OVMS custom endpoint configured.

---

## Top-Level Request Fields

| Field | Value |
|---|---|
| `model` | `QWEN3.6-27B-OV-INT4` |
| `temperature` | `0.1` |
| `top_p` | `1` |
| `stream` | `true` |
| `n` | `1` |
| `stream_options.include_usage` | `true` |
| Messages | 3 |
| Tools | 19 (Ask mode) |

The `include_usage: true` flag is why OVMS reports token counts in the final SSE chunk — the
Copilot extension requests usage stats on every streaming response.

---

## Message 1 — System Prompt (12,826 chars)

The system message is assembled entirely by the Copilot extension at request time. It is never
typed by the user. Sections in order:

### Persona intro (~1,073 chars)
Origin: **Copilot extension hard-coded string**

> "You are an expert AI programming assistant, working with a user in the VS Code editor."

Includes the "GitHub Copilot" name requirement, Microsoft content policy references, and the
instruction to keep answers short and impersonal.

### `<instructions>` (2,015 chars)
Origin: **Copilot extension — agent capability description**

The core agent instructions: research before answering, use tools repeatedly, prefer large file
reads, don't make assumptions, think creatively. These are the same regardless of workspace.

### `<toolUseInstructions>` (2,060 chars)
Origin: **Copilot extension — tool use policy**

Rules about how to use tools: never name tools aloud to the user, call tools in parallel when
possible, don't use `semantic_search` in parallel, always use absolute paths. Also notes which
tools are currently unavailable (e.g. file editing and terminal are disabled in Ask mode).

### `<outputFormatting>` (497 chars)
Origin: **Copilot extension — response style**

Requires GitHub-flavored Markdown, KaTeX for math equations (`$...$` inline, `$$...$$` block),
code references in backticks.

### `<memoryInstructions>` (1,937 chars)
Origin: **Copilot extension — Copilot memory system**

Describes the three-tier memory system used by the Copilot `memory` tool:
- `/memories/` — user memory (loaded into every conversation automatically, first 200 lines)
- `/memories/session/` — per-conversation temporary notes
- `/memories/repo/` — workspace-scoped notes persisted locally

This is **Copilot's own memory**, separate from Claude Code's memory at
`C:\Users\craig\.claude\projects\`.

### `<skills>` (3,172 chars)
Origin: **Copilot extension — installed skill definitions**

Lists 3 skills available in this VS Code installation:

| Skill | Purpose | File |
|---|---|---|
| `project-setup-info-local` | Full project scaffolding (new projects, MCP servers, VS Code extensions) | `copilot/assets/prompts/skills/project-setup-info-local/SKILL.md` |
| `get-search-view-results` | Read current Search panel results | `copilot/assets/prompts/skills/get-search-view-results/SKILL.md` |
| `agent-customization` | Create/edit `.instructions.md`, `.prompt.md`, `.agent.md`, `SKILL.md` files | `copilot/assets/prompts/skills/agent-customization/SKILL.md` |

Skills are loaded lazily — only the name, description, and file path appear here. The model calls
`read_file` on demand to get the full instructions.

### `<modeInstructions>` (2,072 chars)
Origin: **Copilot extension — current chat mode**

Injected based on the selected chat mode (Ask / Agent / Edit). In Ask mode:
- Strictly read-only: no file editing, no state-changing terminal commands
- Can use search and read tools to gather context
- If changes are needed, explain but do not apply

In Agent mode this section instead permits all tool use including file editing and terminal.

### Template Variables
Two variables substituted at request time:
- `VSCODE_USER_PROMPTS_FOLDER` → `C:\Users\craig\AppData\Roaming\Code - Insiders\User\prompts`
- `VSCODE_TARGET_SESSION_LOG` → path to the current session's debug log JSON file

---

## Message 2 — User Context (3,850 chars)

Injected automatically by the Copilot extension before the actual user text. The user never types
this.

### `<environment_info>` (72 chars)
Origin: **VS Code — OS detection**

```
The user's current OS is: Windows
```

### `<workspace_info>` (2,353 chars)
Origin: **VS Code — workspace scanner**

Contains:
1. The list of open workspace folders (`d:\tools\ovms`)
2. A directory tree of the workspace (truncated at ~50 entries with `...`)

The directory tree includes cache files (`.blob`, `.cl_cache`), backup folders, and script files.
This is the largest variable-size contributor after the tool list — a deeply nested or large
workspace will grow this section significantly.

### `<userMemory>` (1,182 chars)
Origin: **Copilot memory tool — `/memories/` scope**

The first 200 lines of the user's persistent Copilot memory files. In this case it contains one
file: `com7-usb-issue.md`, recording a recurring COM7 USB permission issue and the fix (physically
replug the cable). This memory was written by Copilot during a previous session working on an
ESP32-P4 project — unrelated to OVMS but present in every request.

### `<sessionMemory>` (118 chars) / `<repoMemory>` (121 chars)
Origin: **Copilot memory tool**

Both empty in this request — no session or repo memory files exist for the `d:\tools\ovms`
workspace yet.

---

## Message 3 — Actual User Request (1,431 chars)

### `<attachments>` (1,109 chars)
Origin: **VS Code — active editor context**

Two attachments were automatically included:
1. The active **selection** in the editor: the word `Agent` from `chatLanguageModels.json` line 28
2. The full contents of `chatLanguageModels.json` (the currently open file)

VS Code attaches the active file automatically when the chat panel is open. This explains why
Copilot "knows" which file you're looking at even without `@file` being typed.

### `<context>` (54 chars)
```
The current date is May 15, 2026.
```

### `<editorContext>` (186 chars)
Origin: **VS Code — cursor position**

Records the current file path and line selection:
- File: `chatLanguageModels.json`
- Selection: line 28 to 28 (the word `Agent`)

### `<userRequest>` (31 chars)
```
hi
```

The actual user input. The remaining 1,400 chars in this message are all VS Code-generated
envelope.

---

## Tools (Ask Mode — 19 tools, ~19,782 chars)

In Ask mode the Copilot extension sends 19 read-only tools. In Agent mode this grows to 66 tools,
roughly tripling the tool payload and pushing the total prompt from ~18K to ~22K+ characters.

| Tool | Category | Notes |
|---|---|---|
| `fetch_webpage` | Web | Fetch and summarise a URL |
| `file_search` | Workspace | Glob pattern search |
| `grep_search` | Workspace | Fast text/regex search |
| `get_errors` | Editor | Compiler/lint diagnostics |
| `copilot_getNotebookSummary` | Notebook | Jupyter cell listing |
| `github_repo` | GitHub | Semantic code search in a repo |
| `github_text_search` | GitHub | Lexical search across a repo/org |
| `list_dir` | Workspace | Directory listing |
| `memory` | Copilot | Read/write Copilot memory files |
| `read_file` | Workspace | Read file with line range |
| `semantic_search` | Workspace | Natural language codebase search |
| `session_store_sql` | Copilot | Query past session history (SQLite) |
| `view_image` | Workspace | View image files |
| `vscode_askQuestions` | UI | Ask clarifying questions |
| `vscode_listCodeUsages` | Editor | Find references/definitions |
| `get_terminal_output` | Terminal | Get output from a running terminal |
| `renderMermaidDiagram` | UI | Render a Mermaid diagram |
| `terminal_last_command` | Terminal | Get last terminal command |
| `terminal_selection` | Terminal | Get terminal selection |

Note that `get_terminal_output`, `terminal_last_command`, and `terminal_selection` are present even
in Ask mode — but the system prompt's `<toolUseInstructions>` block explicitly tells the model
that file-editing and state-changing terminal tools are *disabled*, so these terminal tools are
listed but constrained by instruction rather than by omission.

---

## Token Budget Summary

| Section | Chars | Approx tokens |
|---|---|---|
| System prompt | 12,826 | ~4,275 |
| User context message | 3,850 | ~1,283 |
| User request message | 1,431 | ~477 |
| Tools (19, Ask mode) | 19,782 | ~6,594 |
| **Total (Ask mode)** | **~37,889** | **~12,630** |
| Tools (66, Agent mode) | ~55,000 est. | ~18,333 |
| **Total (Agent mode)** | **~73,000 est.** | **~24,300** |

Tokenisation estimated at ~3 chars/token (GPT-style BPE). Actual counts depend on model tokeniser.
The OVMS DEBUG log for the Agent mode "hi" request reported 22,387 prompt tokens, consistent with
these estimates.

---

## Key Observations

1. **The "hi" request isn't small.** Even Ask mode sends ~12,600 tokens before the user types a
   word. This is why KV cache sizing matters: `cache_size: 2` (2 GB fixed) was insufficient for
   the 22K-token Agent mode prompt on a 27B model (~112 KB/token × 22K ≈ 2.4 GB needed).
   Setting `cache_size: 0` (dynamic allocation) resolves this.

2. **The workspace tree is variable.** A workspace with hundreds of files in the tree, or deeply
   nested directories, will inflate `<workspace_info>` well beyond the 2,353 chars seen here.

3. **User memory is always included.** The `com7-usb-issue.md` Copilot memory from an unrelated
   ESP32 project appears in every OVMS conversation. Copilot user memory is global and the first
   200 lines are unconditional. Keeping this file small matters.

4. **Active file attachment is automatic.** `chatLanguageModels.json` was attached because it was
   open in the editor. VS Code attaches the active file to give the model context — even for "hi".

5. **Ask vs Agent is the biggest lever.** Switching from Agent to Ask mode removes 47 tool
   definitions, cutting the prompt by roughly half. For conversational use where file editing isn't
   needed, Ask mode is significantly cheaper on the local model.
