# Product and implementation plan

Draft for discussion, November 20, 2026. See the [research and source links](research.md) for the basis of the proposed choices.

## How the assistant should feel

Home is an ongoing conversation with one assistant. Ask anything there. An involved request can open a named task in the sidebar with its own transcript, status, and next action. Returning to Home should let you ask “Where did I leave this?” and jump directly to the relevant passage or unfinished task.

The Mac owns the conversations, search index, and task state. With a hosted model, selected messages and evidence travel to the provider for that turn. The UI should identify the provider and let the owner inspect the sources used. Model sign-in, importing past chats, and opening a new chat in another product each need their own user flow.

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

- **Provider round trip.** Test registration for the local prototype with an eligible account, one streamed response, cancellation, expiry, and reconnect. An API key entered by the owner is the fallback when plan access is unavailable. Store Hereforth credentials in Keychain.
- **Import accuracy.** Build small fixtures for branching, edited messages, repeated imports, missing attachments, and deletion. A citation should still resolve after a title changes. Record whether an old answer used an earlier version of a message.
- **Source and action boundaries.** Exercise two callers against the same question before enabling teammate access. Give the teammate path only its scoped search and request tools. Keep access grants and execution privileges with the identity authorized to use them.
- **Distribution.** Test a signed build on a second Mac and record the minimum macOS version that passes. Choose the open-source license before the public release.
