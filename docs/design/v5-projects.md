# v5: projects, built from connections (#79, #10)

Status: proposal, second draft, for review before any code.

## Why now

Klear work now spans several repos: `klear`, `core-infrastructure` and `claude-plugins` all had PRs merged this month. Pulse assumes one repo, one GitHub org, one Linear workspace and one pile of context. Adding personal repos, or letting someone in ops use Pulse, means mixing their context into Klear's.

## The shape

Pulse is a context nexus. The core is:

- **the nexus**: sources and the dated facts learned from them,
- **tasks**: what needs doing,
- **work items**: the tickets, PRs and other units of work that tools track.

Everything else is either a **connection** that feeds the core or a **feature** built on top of it. Trends, Meetings, Start/Open and the briefing are features.

A **project** is a workspace: a name plus the connections switched on for it. Its nexus, tasks, work items, meetings and briefing are its own, and nothing crosses between projects. GitHub, Linear and Slack stop being built into Pulse and become connections like any other. An engineer, someone in ops and a personal project each shape Pulse by switching on the tools they use, and the features follow:

| Feature | Shows when a connection provides |
|---|---|
| Tasks | always (the briefing finds them in any context) |
| Open work, Done | work items |
| Trends | work items that close (tickets closed, PRs merged) |
| Start / Open in IDE, task sessions | code (repos) |
| Meetings | meeting capture |
| Briefing and Knowledge | any context |

## Connections

A connection provides one or more **capabilities**:

- **context**: something the briefing reads to learn facts and find tasks,
- **work items**: units of work with a state, an owner and dates, synced by Pulse,
- **actions**: things Pulse can do with an item (open it, start it, move its status, draft a reply),
- **meetings**: calls Pulse can recognise and record,
- **identities**: the accounts people have in that tool (name, login, email), so Pulse can tell who's who.

Pulse owns every connection. It signs in to each source itself, per project, and reaches it one of two ways:

- **API**: Pulse calls the tool's own API (Linear GraphQL, GitHub GraphQL, EventKit, Apple Mail, the local repos).
- **MCP client**: Pulse connects to the tool's official MCP server as a client, with its own OAuth sign-in per project, and calls its tools directly. Slack goes this way (`mcp.slack.com`), which also keeps **Draft in Slack** working, because the Slack Web API has no drafts. It's also how a later connection like Notion or HubSpot can be added without writing an API client for each.

The v5 set:

| Connection | Reached by | Context | Work items | Actions | Meetings |
|---|---|---|---|---|---|
| Linear | API | cycles, project and initiative updates, docs (new: today the agent reads these) | tickets | start, move status, open | |
| GitHub | API | issue and PR threads, comments and reviews (new) | PRs; issues (new) | open; start an issue | |
| Code (local repos) | API | agent-session digests | | worktrees, IDE, terminal agents, task sessions | |
| Slack | MCP client | channel history, mentions and DMs (new: today the agent reads these) | | open thread, draft reply | huddles in this workspace |
| Google | API | calendar events | | | Meet calls on this account's calendar |
| Mail | API | Apple Mail accounts | | open message | |

A generic "any MCP server" connection waits until after v5. With Pulse as the client, it needs a way to say which tools to call to gather. That's its own design.

**GitHub as context.** Today GitHub only feeds the open-work list. A project with nothing but GitHub still needs a briefing, so the GitHub connection also exports what changed since the last run (issue and PR threads, comments, reviews) to a file for the briefing, the way Mail does.

**GitHub issues as tickets.** This is how personal projects get tickets, and it's the first test of the abstraction: Done, Start, Trends and the open-work list must treat a GitHub issue exactly like a Linear ticket, with no special cases.

### Pulse is the hub, connections never talk to each other

Every connection talks only to Pulse, and each one stands on its own. Pulse never relies on one tool's integration with another, such as Linear's GitHub integration or Slack's Linear unfurls. If two tools are connected to each other, Pulse ignores that. It makes every link between things itself, from what each connection reports on its own, and keeps the links in the project's nexus:

| Link | How Pulse makes it |
|---|---|
| ticket ↔ PR | the ticket's ID appears in the PR's branch or title (as `mergeTicketsAndPRs` does today) |
| ticket ↔ repo | the PR it's linked to, or a local branch named for it, or your choice in Start in ▸ |
| person ↔ accounts | one person in the project with an identity per connection (Linear name, GitHub login, Slack user, email), matched by email when the connections give one, otherwise confirmed by you once |
| meeting ↔ calendar event | the Meet code in the window title matches the code in the event, both read by Pulse |
| task or fact ↔ ticket, PR, thread | the briefing cites the sources, and Pulse records which items they are |

The rules that follow:

- A connection can be added or removed without breaking another one. Removing GitHub leaves Linear tickets working, just without their PRs.
- Trends and Done count a person once, whichever tools their work came from.
- A ticket closed in Linear is done because Linear says so, and a merged PR is merged because GitHub says so. Pulse never infers one tool's state from another's automation.

The nexus gains two tables:

- `people(id, name)` and `identities(person, connection, handle, email)`, replacing today's `users` and the separate GitHub-login and Linear-name worlds in Trends.
- `links(from_item, to_item, kind, how)` for item-to-item links. `how` says which rule made the link, so you can see why two things are joined.

### Work items replace `issues` and `prs`

One table, `items`: `id, connection, kind (ticket | pr | …), identifier, title, url, container (repo, team), author, assignee, state, created_at, closed_at, size`.

- Trends counts closed items per person per kind. v5 keeps today's two charts (PRs merged, tickets closed), each shown when a connection provides it. Redesigning what Trends is belongs to #25 and #15, not v5.
- Done is "my items closed this week", whatever tool they came from.
- The open-work list (`ActionItem` today) comes from each connection's open items.

Today's `issues` and `prs` rows migrate into it.

### The agent only distills

Today the briefing agent gathers for itself: it reads Linear cycles, updates and docs, plus Slack, through its own MCP servers. Ask's fallback and Draft in Slack work the same way. That ties Pulse to whatever the agent happens to be signed in to, which breaks the silo: one Slack MCP server is signed in to one workspace for every project.

In v5, Pulse gathers and the agent only distills:

1. **Gather.** Each of the project's context connections fetches what's new since the last run, and Pulse writes it into the run's folder: one file per connection, every item with its URL, author and date. Mail, meetings and session digests already work this way. Linear, Slack and GitHub join them.
2. **Distill.** Pulse calls the briefing agent with those files, the known facts and the open tasks. The agent gets **no tools except reading those files and writing its three outputs**: no MCP servers, no shell, no network. It returns fact changes, task changes and the briefing, exactly as today. The prompt is assembled from the connections present, so it only ever mentions the project's own sources.
3. **Ask.** When the on-device model can't answer, the agent's only tool is Pulse's own MCP server, scoped to the project. It gets `search` and `subject`, plus a new `lookup` that searches the project's connections live (Linear, Slack, GitHub search) through Pulse.
4. **Draft in Slack** and every other action is Pulse calling the connection directly, with no agent.

What this buys:

- The silo holds by construction, because the agent can only see what Pulse hands it.
- The briefing is read-only by construction rather than by prompt.
- Any agent works, since it needs no MCP setup.
- Runs are cheaper and repeatable, because gathering is plain code.
- The cost is that Pulse has to fetch Linear's cycles, updates and docs and Slack's channels, mentions and DMs itself. That's new code, but it's explicit.

## Test projects: Pulse and Vellum

Beta 5 is tested by adding two personal projects next to Klear. Each has only a GitHub connection and a Code connection:

```json
{ "name": "Pulse", "connections": [
    { "type": "github", "account": "andymitch", "repos": ["andymitch/pulse"], "issues": true },
    { "type": "code", "repos": [{ "path": "~/dev/pulse" }] } ] }
```

Vellum is the same with `andymitch/vellum` and `~/dev/vellum`. They check that:

- A project with no Linear, Slack, Google or Mail still gets open work, Done, Start, Trends and a briefing, all from GitHub alone.
- GitHub issues behave as tickets: open, start a worktree, closed ones in Done.
- Each project uses its own GitHub account (`andymitch`, not `andrew-klear`) and repo list.
- Nothing about Klear appears in Pulse or Vellum, and the reverse: in the app, over MCP and in the briefing.
- Pulse and Vellum are siloed from each other too, even though they share an account.

## Projects on disk

Each project gets its own folder:

```
settings.json            global: IDEs, agents, briefing command and hour, voice, hotkey, updates, appearance, agent access, default project
projects/<id>/
  project.json           name and connections
  pulse.db               nexus, tasks, items, marks, meta
  secrets/               one file per connection sign-in (Linear key, Slack OAuth token, …), never shared between projects
  synthesis.json, meetings/, sessions/, prompts/, mail/
```

`project.json`:

```json
{
  "name": "Klear",
  "connections": [
    { "type": "linear", "key": "secrets/linear" },
    { "type": "github", "account": "andrew-klear", "owners": ["klearbusiness"], "issues": false },
    { "type": "code", "repos": [
        { "path": "~/dev/klear", "worktrees": "~/dev/worktrees/klear" },
        { "path": "~/dev/core-infrastructure" },
        { "path": "~/dev/claude-plugins" } ] },
    { "type": "slack", "workspace": "klearbusiness", "token": "secrets/slack", "channels": [], "meetings": true },
    { "type": "google", "account": "andrew@klear.com", "meetings": true },
    { "type": "mail", "accounts": ["Klear"], "days": 3 }
  ]
}
```

Projects are completely siloed: nothing is shared between them, including people. The same teammate in two projects is two unrelated subjects.

GitHub's `owners` takes orgs or users. `repos` limits it to named repos instead.

Why folders and not a `project` column: everything Pulse keeps moves unchanged into the project's folder, and code that takes `dir`/`db` just gets the project's. A forgotten filter can't leak one project into another, because the other project's data isn't in the file. Deleting a project deletes its folder. The unused `project` column on facts stays at `'default'`.

## Meetings, per project

Meeting capture is a capability of the **Google** and **Slack** connections, switched on per project ("Record Meet calls on andrew@klear.com", "Record huddles in klearbusiness"). Pulse only records a call when it can name the project that claims it. Here is how each call is recognised:

- **Meet with a calendar event.** EventKit gives the event's calendar, and the calendar's account (`calendar.source`). The Meet window's title (`Meet - abc-defg-hij`) matches the Meet link in the event. Account → project. This works today. It needs the Google account added in macOS Calendar, which Pulse already asks for.
- **Slack huddle.** Pulse sees Slack using the mic. Slack lists the signed-in workspaces (`root-state.json`: id, domain, name), and its window title includes the workspace name. Workspace → project. With one workspace signed in it's trivial. With several, the title match needs checking in beta.
- **Meet with no calendar event (ad hoc).** Nothing reliable says which Google account it's on. Pulse can't tell, so it asks: a notification with "Record for Klear / Personal / Skip". If only one project records Meet calls, it goes straight there. No guessing.
- **Manual "Start recording"** records into the active project.

A meeting can still be moved to another project from its card.

## Repos within a project (#10)

- Sync and the open-PR search use the GitHub connection's `owners` (`org:` or `user:`), with that connection's account token.
- A ticket's repo is picked in this order. A team mapping wouldn't work, because Klear's one KLE team spans all its repos.
  1. A PR Pulse has linked to the ticket (by the ID in its branch or title) names the repo.
  2. A local branch with the ticket's branch name exists in one repo.
  3. Otherwise the first repo, with a **Start in ▸** menu to pick another. The choice is remembered per ticket.
- Worktrees stay `<worktrees>/<ticket>/<repo>`, so a ticket across two repos gets one worktree per repo.
- Session digests cover every repo and worktree folder in the project.
- Task sessions start in the repo a task's link names, otherwise the first repo.

## Switching projects

A project is a top-level workspace:

- The picker sits next to the "Pulse" title and only appears with two or more projects.
- Switching swaps the whole UI: tasks, focus, Knowledge, Meetings, Trends and Settings' project pages.
- The menu bar count and the hotkey belong to the active project.
- Every project keeps syncing and briefing in the background, so switching is instant. One briefing per project runs at the briefing hour, one after another.

## MCP

Every tool takes an optional `project` argument, and a new `projects` tool lists them. One call only ever reads or writes one project, so answers never mix. The project for a call is chosen in this order:

1. The `project` argument.
2. `Pulse --mcp --project <id>`, for an agent config dedicated to one project.
3. The folder the MCP server was started in, when it's inside one of a project's repos or worktrees.
4. The **default project** set in Settings.
5. If there's no default, an error that lists the projects and says to pass `project`.

Every response names the project that answered. Writes post the project id with their change notice, so the app reloads just that project. Agents outside a repo still use Pulse; they pass the project, or get the default.

## Settings

- **General**: the global settings, including the **default project** (or "None, always ask").
- **Projects**: add, rename and remove projects. Each project has a **Connections** list: add one, sign in to it, and switch its capabilities (meetings, GitHub issues) on or off.

## Migration (first v5 launch)

1. Create `projects/klear/` (named after the Linear workspace), and set it as the default project.
2. Move `pulse.db`, `linear-key`, `synthesis.json`, `meetings/`, `sessions/`, `prompts/` and `mail/` into it.
3. Turn today's settings into connections:
   - Linear (key),
   - GitHub (`githubAccount`, `githubOrg`),
   - Code (`repoPath`, `worktreeRoot`),
   - Slack (`slack`, `slackChannels`, plus meetings if `recordMeetings` is on),
   - Google (each calendar account, with meetings if `recordMeetings` is on),
   - Mail (`mail`, `mailDays`).
4. Copy `issues` and `prs` into `items`.
5. Leave a `moved-to-projects` marker so a downgrade fails loudly instead of starting empty.

The self-test covers migrating a v4 folder, and checks that a second project sees none of the first one's facts, tasks or items.

## Delivery (betas)

1. **v5-beta.1: one project underneath.** Folders, migration, `project.json`, per-project Store and MCP with the `project` argument. No visible change.
2. **v5-beta.2: connections.** Today's sources become connections (Linear, GitHub, Code, Slack, Mail, Google), each with its own sign-in. Work items move to `items`, features show by capability, and Settings gets a project's Connections page.
3. **v5-beta.3: Pulse gathers, the agent distills.** Linear, Slack (as an MCP client) and GitHub fetch the briefing's context. The briefing agent runs with no tools. Ask's fallback gets Pulse's MCP with `lookup`, and Draft in Slack goes through Pulse.
4. **v5-beta.4: several repos and GitHub issues (#10).** The Code connection takes many repos, plus Start in ▸, multi-repo sync and digests. Issues work as tickets. Klear gets its three repos.
5. **v5-beta.5: several projects (#79).** Picker, per-project briefings, meeting routing and the ask-on-unknown notification, default project. Add Pulse and Vellum as test projects.
6. **v5.** Fixes from the betas.

Each beta gets its own issue under the v5 milestone.

## Still open

1. **Slack sign-in.** Pulse needs its own Slack OAuth client for `mcp.slack.com`, as pi's config has one today. Either Pulse registers a Slack app once and every project signs in with it, or each person brings their own client id. The Klear workspace may need an admin to approve the app either way. To check at the start of beta 3, before building on it.

## Related

- #25 (making Pulse generic for non-engineers): connections and capability-driven features are most of its "sources" question. Its role presets and custom sections stay there.
- #15 and #25 own the Trends redesign.
