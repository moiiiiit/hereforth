# Product and implementation plan

November 20, 2026. Hereforth is free to install and self-host. The Mac app and assistant connector ship together under the [MIT license](../LICENSE). An owner can use their existing Claude client for inference. The local recall and handoff path needs no Hereforth account, team subscription, or API key. The user's assistant plan and organization settings still apply.

## Decisions and handoffs first

One person can recover decisions across their own chats. When two teammates install Hereforth, each can publish a named session to receive context. Comity provides a useful model for carrying forward the objective, decisions, attempts, and remaining work. Hereforth addresses the suggestion to the selected session and lets its owner review it before the assistant reads it. [Comity handoffs](https://comity.so/docs/collaboration/handoffs) · [Public feature requests and competing products](product-assessment.md)

| Priority | Workflow | Acceptance check |
| --- | --- | --- |
| 1. Recall a decision | Import two chats. Ask Claude what the team decided, why, and whether it changed. Return dated passages that Claude can cite and open. | One chat proposes Thursday and a later chat confirms Friday. The answer distinguishes the proposal from the decision, cites both, and says when the available evidence is ambiguous. Follow a citation after restarting the connector. |
| 2. Hand off to another person | Ask Claude to send the decision and next step to Ryan’s published release session. Ryan reviews the text in his Hereforth Inbox. | Pending and declined text stay out of the assistant. After approval, only the intended session can collect the text. Mohit can ask whether it arrived. Ryan retains control of any subsequent action. |
| 3. Route a blocker | Ask “Who needs an answer from me?” A named recipient can acknowledge the question, answer it, or ask for a discussion. | Return the response to the person waiting and reflect the change in the next standup. Track how long the question waited and whether the organizer could shorten the sync. |
| 4. Follow an answer | From a dated launch answer, ask “Tell me if this changes.” Subscribe to a specific shared decision and choose when to stop following it. | A newly approved change triggers one update with a readable citation. Replaying it produces no duplicate. A revoked or expired grant stops delivery. |

Follow the first release with PR-backed evidence and explicit decision corrections. An agent finishing a turn, a PR merging, and a person confirming a decision each represent different facts. Test them against a real handoff before expanding the source list. The open-source pilot succeeds when people return unprompted, need fewer clarification messages, and save time on an actual sync. Pair both teammates’ Hereforth installations and exercise approval and delivery using their own assistants.

## How the assistant should feel

Use Hereforth from an existing assistant. After one-time connection and consent, a teammate asks their own Claude “What is Mohit working on right now?” The answer appears inline, together with any confirmed blockers and the age of the evidence. An owner can ask “Where did I leave this?” in the same way. Each task has a stable identity and transcript across clients. The Mac can also provide an optional Home conversation.

The Mac owns the conversations, search index, and task state. With a hosted model, selected messages and evidence travel to the provider for that turn. The answer should identify the evidence it used, and the owner can ask which provider handled a turn. Model sign-in, importing past chats, and opening a new chat in another product each need their own user flow.

## Asking from Claude

Treat every view as a query that an assistant can discover and invoke. Ship its read operation and conversational acceptance case with the feature. The Mac and phone can render the same result. One-time connection, macOS permissions, and sensitive action approvals can still require human interaction.

**Team status demo.** A colleague asks their own Claude, “What is Mohit working on right now?” Hereforth resolves Mohit from the caller’s accepted connections and reads his shared work. An illustrative reply is “Mohit’s latest update says he’s preparing the launch brief. His Codex agent started integration tests four minutes ago. The brief is waiting on an audience decision.” Each statement carries its own timestamp and evidence reference. Claude can answer “What decision?” from those references without opening Hereforth. Distinguish the owner's reported focus from work delegated to an agent. When only agent activity is known, attribute it to the agent.

| Information the caller wants | Example question | What Hereforth returns |
| --- | --- | --- |
| Current work and decisions | What is Mohit working on? What needs my input? | Approved personal updates, agent states, blockers, decision owners and last observations within the caller's grants. |
| Team standup | Give me the team standup. Who needs a review today? | A list grouped by teammate covering recent progress, current work, and requests for help. |
| Memory, sessions and sources | Where did we decide on Thursday? What did the meeting say? | Matching passages, dates, session IDs and citations the caller can resolve inside chat. |
| Async check-ins | What changed since our last sync? Which questions are still open? | Changes since the selected update, reviewed blockers, open questions, and recorded meeting outcomes. |
| Usage and budgets | How much did this project use this week? | Permitted totals by provider, billing mode and period, including unknown coverage and freshness. Owner access by default. |
| Availability and control status | Is my Mac reachable? Why is it awake? Did my task finish? | Last observation, effective awake reasons and expiry, task state and outstanding approvals within the caller’s role. |
| Access and sharing | Who can see this update? What happened to my access request? | Effective audience for an authorized owner, or the caller’s own request status and decision. |

Give the model typed MCP tools with descriptions, validated filters and structured results. For example, an activity read accepts a connected owner ID and optional project. The service derives the requester from the authenticated connection and applies grants before returning titles, counts or passages. Include observation time, coverage and citation IDs with results. Resolve each follow-up against current grants. A read consumes Hereforth records without invoking a second LLM or granting control of the Mac. Task execution, publication, and access changes use separate action tools and their existing approval rules. [MCP tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools) · [MCP authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)

**Connection and discovery.** For the pilot, Mohit sends an invitation binding his Hereforth identity and endpoint to a display name. The teammate connects once in Claude. Offer only accepted connections to that caller. If two people match a name, ask the caller to choose using a shared team or handle. A local Claude Code client can reach an authenticated HTTP MCP endpoint over the LAN or tailnet. For Claude web, desktop or mobile using its hosted connector, provide an opt-in internet-reachable HTTPS gateway. The Mac connects outbound. Authenticate each caller, bind their identity and intended owner to the request, and have the Mac enforce grants for every read. The gateway and caller’s model may process the returned shared fields. Keep the gateway limited to reads in this pilot. [Claude Code MCP connections](https://code.claude.com/docs/en/mcp) · [Hosted Claude connector networking](https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp)

**Release check.** Run the question and a follow-up from a teammate's Claude with all Hereforth windows closed. Repeat as a second teammate with different grants, after revoking a citation, and with the Mac offline. Return a timestamped last-known result only when current authorization can be checked. Otherwise report that current status is unavailable. For a reachable but empty result, say “No current update is shared with you.” Test the local and hosted Claude connections separately.

## What my agents are working on

Expose agent activity as a read query. Its records include the task objective, project, agent, current step, time of the last confirmed activity, and any decision needed. The owner's assistant can present requests needing input first and retrieve the underlying evidence in a follow-up. The optional Home and phone views consume the same records. Group child agents under the task they are helping with. Keep recent results available below active work so the owner can find what finished while they were away.

| Task | Agent | Last confirmed activity | Next action |
| --- | --- | --- | --- |
| Prepare the launch brief | Claude Code | Needs your input · asked 4 min ago | Choose the audience |
| Check the release candidate | Codex | Working · started integration tests 1 min ago | Open run |
| Update the onboarding guide | Cursor | Connection lost · last seen 18 min ago | Open session |

Derive the state from the task runner or a connected provider. Store the run ID, parent task, last observed event and time. Use a provider event ID or sequence when available to handle duplicates and late events. On reconnect, reconcile with the source before labeling work live again. Frame a finished model turn as a finished step until the task runner confirms the task outcome. A transcript import or browser handoff can show its last known activity. When coverage is missing, say “Live status unavailable.” A quiet but connected run may simply be waiting for a long operation.

Start with Hereforth-owned tasks in milestone 1. In milestone 2, use Codex app-server lifecycle events for connected threads and evaluate opt-in Claude Code and Cursor hooks for runs started in those tools. Their documented hooks include child-agent lifecycle events. The installed Codex schema exposes thread status changes and turn start/completion events. End-to-end status delivery across the three apps remains a pilot test. [Codex app-server](https://developers.openai.com/codex/app-server) · [Claude Code hooks](https://code.claude.com/docs/en/hooks) · [Cursor hooks](https://cursor.com/docs/hooks)

For the check-in pilot, let the owner share a task under a reviewed project title with named teammates. Offer an explicit **Share live status** option for that task. Teammates can see the approved title, working/waiting/finished state, freshness, and an optional reviewed blocker or result. A viewer can ask “What's waiting on our team?” and see the same authorized rows. Keep permission to respond to an approval or control a task with the owner. [Sharing and revocation](teammate-knowledge.md)

To test the section, start two tasks, put one into a waiting state, disconnect the other adapter, then reconnect and deliver its completion twice. An owner asking from Claude should hear about one outstanding decision and one finished task. A teammate invited to only the first task sees only its approved fields, including in counts and answers. Revoking its grant removes the row and stops further status delivery to that viewer.

## Team standup

The current `team_standup` tool reads the latest owner-written update shared with the caller by each of up to 20 paired teammates. It also accepts an explicit list of names. An unavailable Mac and a reachable Mac with no active share get distinct results. A shared entry includes the time and thread for follow-up. The next step is comparing reports across time. [Current walkthrough](teammate-knowledge.md)

### Planned reporting periods

“Give me the team standup” returns one short entry per teammate, directly in the caller's Claude. Use their current team, or ask which team if the choice is ambiguous. Include what changed since the previous team standup, what is underway now, and any blocker or request for help. On the first standup use the last working day and show the date range. Keep ongoing blockers visible even if they predate that range. A reader can follow up with “Only blockers” or “What does Priya need from me?”

Example with fictional updates:

- **Mohit** finished the connector draft. His Codex agent is running integration tests. Needs Priya to confirm the OAuth scopes. Updated 9:20 am.
- **Priya** reviewed the mobile build and is fixing the sign-in issue. Updated 9:05 am.
- **Alex** has no shared update for this period.

Extend the read-only `team_standup` tool with saved teams and an optional start time. Resolve membership from the team roster visible to the caller. Request each member’s shared updates with the caller’s identity, then group the results by person. Keep the source and observation time for each item so Claude can answer follow-ups. Reading the list leaves the team's reporting period unchanged. Use the last published standup as the shared baseline.

Return the available entries when a member's Mac is offline, with a coverage note for that member. Distinguish “couldn't check” from “no shared update.” Reuse previously published entries only while the caller's grant can be verified. Teammates can read at different times without generating another model summary on every owner's Mac.

Pilot with three teammates. Ask for the standup from Claude, then ask who needs a review. Repeat as a caller with fewer grants and with one Mac offline. Both questions should return the permitted evidence, preserve attribution, and work with every Hereforth window closed.

## Replacing routine status syncs

The one-to-one path starts with a natural request such as “Ask Ryan for his standup.” Approval creates a dedicated Hereforth thread with the owner's reviewed opening update. Follow-ups stay in the thread and either assistant can reopen it. The owner's weekly evidence is a private input to preparing an update. The team-wide read should roll up the latest owner updates a caller can access, preserve their timestamps, and let the caller follow up in the corresponding thread. [Standup access and follow-ups](teammate-knowledge.md#ask-for-someones-standup)

Pilot with one recurring project check-in. Before the next occurrence, ask Hereforth “What changed since our last update, what's blocked, and who needs to decide?” Draft a short update from the prior published version and newer evidence. Include the time covered, links to the evidence the audience can read, the person who could unblock the work, and any decision needed. An unknown owner or stale status should stay visible as such. Have the project owner review and publish the update to named teammates. Each reader can ask follow-up questions against their own grants. [Teammate sharing design](teammate-knowledge.md)

Show readers which questions have already been answered and which still need discussion, within their authorized audience. Let the organizer mark the occurrence **resolved asynchronously**, **discussion needed**, or **held as usual**. When discussion is needed, use the open questions as the agenda. Record the outcome explicitly. A generated update or a missed calendar event alone cannot establish that a meeting was avoided.

After several occurrences, compare organizer-confirmed meetings replaced or shortened, aggregate attendee-minutes saved, time spent preparing updates, and questions still waiting for an answer. Use the team's feedback on missing or stale evidence to decide what to connect next.

## Proposed first build

Keep the query service and SQLite store in a per-user macOS process that can run with all windows closed. SwiftUI supplies optional setup, inspection, and approval surfaces. The service answers structured reads directly from authorized local records. The caller’s LLM phrases the answer. Hereforth uses its own provider connection for owner-initiated generation when needed.

1. Store conversations, messages, and source references. Give imports a stable key based on account, source, and external ID. Keep speaker, timestamps, message order, branch ancestry when available, and a locator for the original passage. Update a source and its FTS5 index in one transaction.
2. Assemble each turn from the current task, selected preferences or decisions, and relevant excerpts from other permitted sources. Target up to roughly 200k tokens of task detail when the selected model allows it. Reserve space for tool results and the reply first. Summarize older turns with links to the originals when the budget is smaller.
3. Start with full-text search and a short list of ranked excerpts. Keep a small set of questions with known answers, including paraphrases and a later decision that supersedes an earlier one. Use the missed questions to decide whether embeddings would improve recall.
4. Attach citations to stable message IDs. Clicking one opens the passage locally after restart. Scope derived summaries to their sources. Removing a source must also remove its index entries and invalidate memories derived from it.

### Working context for this week

“What did I work on this week?” needs coverage across projects. Start with a compact inventory of the conversations with dated activity since Monday in the owner's time zone. A short support handoff should appear alongside a release chat with hundreds of turns. Drill into a conversation for excerpts and open a citation for the passage behind a decision. When only part of the week has been read, say which part. Use the passage timestamp for inclusion. Plain text without a reliable timestamp remains searchable outside the weekly view.

Keep one canonical copy of the imported passage and an external-content full-text index. Use date-range indexes to locate weekly evidence, a byte budget for each evidence page, and a cursor for the next page. Old conversations remain available when a current question refers back to them. Storage capacity and the assistant's per-turn context window are separate budgets. [SQLite external-content indexes](https://www.sqlite.org/fts5.html#external_content_tables) · [SQLite index planning](https://www.sqlite.org/queryplanner.html#multi_column_indices)

An unresolved blocker from last Friday can still matter on Monday. The next layer should track explicit, dated decisions and open commitments with links back to their evidence. Carry them forward until newer evidence resolves or supersedes them. Evaluate this on a week containing a reversal, an unresolved item from the previous week, and a quiet project. Add summaries or semantic retrieval when a measured recall gap justifies the extra storage and maintenance. An owner chooses the words that enter a teammate's standup.

## Milestones

| Milestone | What to build | Demonstration |
| --- | --- | --- |
| 1a. Personal memory and session handoffs | Local MCP, native import, cross-chat evidence, named receiver sessions, authenticated peer offers, and owner consent. Use the caller’s assistant for inference. | Mohit recovers the final decision from two chats. Ryan admits the proposed context to his running release session. Another session gets nothing. |
| 1b. Team pilot | Verify per-recipient grants, connect the first live activity source, and add the team standup read. Test a named blocker and a single decision watch with the same recipients. | From a teammate’s Claude, read only shared tasks, answer a blocker, and follow a changed decision. A revoked recipient receives no future update. |
| 2. Connected work | Add Granola notes and selected Cursor sessions. Open an existing source or start a task in the user's chosen tool. Persist its external ID once known. | Use a meeting decision and a coding session to prepare a brief. Start a new session in a supported tool, then open the same session from Home after restart. Test ChatGPT web and Claude web separately from Codex and Claude Code. |
| 3. Owner access from another device | Pair a second device. Expose owner conversation and task status reads to the paired client through the same query service. Add a small set of owner-invoked Mac actions, with cancel and visible results. Start with opening a selected document or app. | From a paired phone, resume a task and open its document on an awake Mac. Show when the Mac is asleep, a permission was denied, or an action was interrupted. Reconnect without replaying a completed action. |
| 4. Teammate questions and requests | Give each caller an identity and explicit access to particular sources or projects. Apply those grants before retrieval, including summaries, citations, and cached results. Record who requested an action and who approved it. | A colleague receives a cited project update from a shared source. A private chat on the same topic stays private. An IT access request goes to the authorized approver. Revoking a grant takes effect on the next query. |

## First implementation decisions to test

The Mac app supports timed Keep Awake and on-demand usage reports from local Claude Code, Codex, and Kimi Code logs. Add task-linked Keep Awake and phone controls to the owner remote pilot in milestone 3. Add scheduled team availability, reviewed update reuse, and per-project usage reporting for the asynchronous check-in pilot in milestone 4. [Keep Awake and usage controls](availability-and-usage.md)

For milestone 3, the [remote control design](remote-control.md) specifies owner pairing, scoped task approvals, manual desktop handoff, and a two-device pilot over cellular.

- **Provider round trip.** Test registration for the local prototype with an eligible account, one streamed response, cancellation, expiry, and reconnect. An API key entered by the owner is the fallback when plan access is unavailable. Store Hereforth credentials in Keychain.
- **Import accuracy.** Build small fixtures for branching, edited messages, repeated imports, missing attachments, and deletion. A citation should still resolve after a title changes. Record whether an old answer used an earlier version of a message.
- **Teammate access.** Start the two-person retrieval experiment alongside the personal memory milestone. Use owner-reviewed, versioned project notes for the first teammate Claude pilot. Test two callers asking the same question, following citations, and losing access mid-answer. [Sharing design and acceptance criteria](teammate-knowledge.md)
- **Distribution.** Provide a local source install under the MIT license. Test a signed, notarized download on a second Mac before offering a public binary release.

## Workplace request pilot

Use the same conversational front door for IT support, security review, time-limited data access, and vendor intake. A person-addressed request is durable after it reaches their peer service. It can arrive with no published session. The assistant categorizes it, the recipient reviews it at their desk, and a supported adapter records fulfillment automatically. The first implemented effect grants seven days of read-only access to one reviewed Hereforth brief revision. External data access remains a separate integration. If a recipient’s Mac is offline, submission currently fails and the sender can retry with the same request ID. Add a retrying outbox if pilot teams frequently encounter this. [Worked examples and pilot criteria](workplace-requests.md)
