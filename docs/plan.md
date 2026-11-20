# Product and implementation plan

Draft for discussion, November 20, 2026. See the [research and source links](research.md) for the basis of the proposed choices.

## How the assistant should feel

Home is an ongoing conversation with one assistant. Ask anything there. An involved request can open a named task in the sidebar with its own transcript, status, and next action. Returning to Home should let you ask “Where did I leave this?” and jump directly to the relevant passage or unfinished task.

The Mac owns the conversations, search index, and task state. With a hosted model, selected messages and evidence travel to the provider for that turn. The UI should identify the provider and let the owner inspect the sources used. Model sign-in, importing past chats, and opening a new chat in another product each need their own user flow.

## What my agents are working on

Put this section on Home and on the paired phone. Give each active task one row with its objective, project, agent, current step, time of the last confirmed activity, and any decision it needs. Put requests for the owner's input first. Selecting a row opens the originating session or the decision awaiting review. Group child agents under the task they are helping with. Keep recent results available below active work so the owner can find what finished while they were away.

| Task | Agent | Last confirmed activity | Next action |
| --- | --- | --- | --- |
| Prepare the launch brief | Claude Code | Needs your input · asked 4 min ago | Choose the audience |
| Check the release candidate | Codex | Working · started integration tests 1 min ago | Open run |
| Update the onboarding guide | Cursor | Connection lost · last seen 18 min ago | Open session |

Derive the state from the task runner or a connected provider. Store the run ID, parent task, last observed event and time. Use a provider event ID or sequence when available to handle duplicates and late events. On reconnect, reconcile with the source before labeling work live again. Frame a finished model turn as a finished step until the task runner confirms the task outcome. A transcript import or browser handoff can show its last known activity. When coverage is missing, say “Live status unavailable.” A quiet but connected run may simply be waiting for a long operation.

Start with Hereforth-owned tasks in milestone 1. In milestone 2, use Codex app-server lifecycle events for connected threads and evaluate opt-in Claude Code and Cursor hooks for runs started in those tools. Their documented hooks include child-agent lifecycle events. The installed Codex schema exposes thread status changes and turn start/completion events. End-to-end status delivery across the three apps remains a pilot test. [Codex app-server](https://developers.openai.com/codex/app-server) · [Claude Code hooks](https://code.claude.com/docs/en/hooks) · [Cursor hooks](https://cursor.com/docs/hooks)

For the check-in pilot, let the owner share a task under a reviewed project title with named teammates. Offer an explicit **Share live status** option for that task. Teammates can see the approved title, working/waiting/finished state, freshness, and an optional reviewed blocker or result. A viewer can ask “What's waiting on our team?” and see the same authorized rows. Keep permission to respond to an approval or control a task with the owner. [Sharing and revocation](teammate-knowledge.md)

To test the section, start two tasks, put one into a waiting state, disconnect the other adapter, then reconnect and deliver its completion twice. Home should show one outstanding decision and one finished task. A teammate invited to only the first task sees only its approved fields, including in counts and answers. Revoking its grant removes the row and stops further status delivery to that viewer.

## Replacing routine status syncs

Pilot with one recurring project check-in. Before the next occurrence, ask Hereforth “What changed since our last update, what's blocked, and who needs to decide?” Draft a short update from the prior published version and newer evidence. Include the time covered, links to the evidence the audience can read, the person who could unblock the work, and any decision needed. An unknown owner or stale status should stay visible as such. Have the project owner review and publish the update to named teammates. Each reader can ask follow-up questions against their own grants. [Teammate sharing design](teammate-knowledge.md)

Show readers which questions have already been answered and which still need discussion, within their authorized audience. Let the organizer mark the occurrence **resolved asynchronously**, **discussion needed**, or **held as usual**. When discussion is needed, use the open questions as the agenda. Record the outcome explicitly. A generated update or a missed calendar event alone cannot establish that a meeting was avoided.

After several occurrences, compare organizer-confirmed meetings replaced or shortened, aggregate attendee-minutes saved, time spent preparing updates, and questions still waiting for an answer. Use the team's feedback on missing or stale evidence to decide what to connect next.

## Proposed first build

Use one SwiftUI app and one SQLite database under Application Support. Home and task conversations share a store. For the first build, the app runs while open and calls the model directly. Add a helper process when a specific feature needs to outlive the window or interact with another application.

1. Store conversations, messages, and source references. Give imports a stable key based on account, source, and external ID. Keep speaker, timestamps, message order, branch ancestry when available, and a locator for the original passage. Update a source and its FTS5 index in one transaction.
2. Assemble each turn from the current task, selected preferences or decisions, and relevant excerpts from other permitted sources. Target up to roughly 200k tokens of task detail when the selected model allows it. Reserve space for tool results and the reply first. Summarize older turns with links to the originals when the budget is smaller.
3. Start with full-text search and a short list of ranked excerpts. Keep a small set of questions with known answers, including paraphrases and a later decision that supersedes an earlier one. Use the missed questions to decide whether embeddings would improve recall.
4. Attach citations to stable message IDs. Clicking one opens the passage locally after restart. Scope derived summaries to their sources. Removing a source must also remove its index entries and invalidate memories derived from it.

## Milestones

| Milestone | What to build | Demonstration |
| --- | --- | --- |
| 1. Personal memory | SwiftUI Home and task list, user-selected ChatGPT and Claude exports, SQLite search, one eligible ChatGPT sign-in and streamed answer. Start with synthetic fixtures. | Import two chats about the same project, one containing the decision and one the reason. Ask from a fresh task and obtain both citations. Reimport, quit, and reopen. The same citations resolve once each. Cancel a stream and resume the conversation. |
| 2. Connected work | Add Granola notes and selected Cursor sessions. Open an existing source or start a task in the user's chosen tool. Persist its external ID once known. | Use a meeting decision and a coding session to prepare a brief. Start a new session in a supported tool, then open the same session from Home after restart. Test ChatGPT web and Claude web separately from Codex and Claude Code. |
| 3. Owner access from another device | Pair a second device. Offer a phone-friendly conversation and task status view. Add a small set of owner-invoked Mac actions, with cancel and visible results. Start with opening a selected document or app. | From a paired phone, resume a task and open its document on an awake Mac. Show when the Mac is asleep, a permission was denied, or an action was interrupted. Reconnect without replaying a completed action. |
| 4. Teammate questions and requests | Give each caller an identity and explicit access to particular sources or projects. Apply those grants before retrieval, including summaries, citations, and cached results. Record who requested an action and who approved it. | A colleague receives a cited project update from a shared source. A private chat on the same topic stays private. An IT access request goes to the authorized approver. Revoking a grant takes effect on the next query. |

## First implementation decisions to test

Instrument model usage in milestone 1. Add task-linked and timed Keep Awake to the owner remote pilot in milestone 3. Add scheduled team availability, reviewed update reuse, and per-project usage reporting for the asynchronous check-in pilot in milestone 4. [Keep Awake and usage controls](availability-and-usage.md)

For milestone 3, the [remote control design](remote-control.md) specifies owner pairing, scoped task approvals, manual desktop handoff, and a two-device pilot over cellular.

- **Provider round trip.** Test registration for the local prototype with an eligible account, one streamed response, cancellation, expiry, and reconnect. An API key entered by the owner is the fallback when plan access is unavailable. Store Hereforth credentials in Keychain.
- **Import accuracy.** Build small fixtures for branching, edited messages, repeated imports, missing attachments, and deletion. A citation should still resolve after a title changes. Record whether an old answer used an earlier version of a message.
- **Teammate access.** Start the two-person retrieval experiment alongside the personal memory milestone. Use owner-reviewed, versioned project notes for the first tailnet browser pilot. Test two callers asking the same question, following citations, and losing access mid-answer. [Sharing design and acceptance criteria](teammate-knowledge.md)
- **Distribution.** Test a signed build on a second Mac and record the minimum macOS version that passes. Choose the open-source license before the public release.
