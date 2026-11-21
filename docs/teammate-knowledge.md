# Sharing personal knowledge with teammates

## Ask for someone’s standup

Both teammates connect Hereforth to the assistant they already use and [pair their installations](session-context.md). A standup belongs to a person and can outlive any Claude or Codex chat. A teammate can ask for one even when the owner has no published assistant sessions.

| In the conversation | What Hereforth does |
| --- | --- |
| Mohit asks, “What is Ryan working on this week?” | Mohit's assistant looks for a standup thread he can already read at Ryan's Hereforth. If it finds one, it reads Ryan's latest update and gives the date. If it finds none, it offers to ask Ryan. An absent update says nothing about how busy Ryan is. |
| “Ask Ryan for his standup so I can plan the docs review.” | A request with that reason appears in Ryan's Work Requests. Ryan can decide at his desk. He can consult **This Week** privately to recall what changed. |
| Ryan reviews “The pilot will ship two export templates. The docs review is the remaining blocker.” | Approval opens a new Hereforth thread for Ryan and Mohit with exactly those words as its first message. Ryan sees the recipient and seven-day duration before approving. His provider conversations, their titles and their private citation IDs stay in his library. |
| “Which template needs review first?” | If the approved messages answer the question, Mohit's assistant can cite the dated update. Otherwise it can offer to post the question to the thread. Ryan can reply there from his own assistant or from Hereforth. A question stays open until someone answers it. |
| Mohit opens Codex the next day and asks, “What did Ryan say about the docs review?” | Codex can find the same authorized thread at Ryan's Hereforth and read the exchange. Mohit doesn't need the original Claude chat or a saved thread ID. Expiry or revocation ends future peer reads and replies. Previously delivered text may still be in either assistant's history. |

Each approved request creates its own conversation with that requester. Ryan can give another teammate a different update while keeping Mohit’s questions in their own thread. Publishing a session to receive [a context suggestion](session-context.md) remains a separate, deliberate action.

## Read a team standup

After [pairing with your teammates](session-context.md#pair-teammates), ask “Give me the team standup from Hereforth. Include the date of each update and say whose update you couldn’t read.” You can also name a group, such as “Give me the standup from Ryan Pate and Priya Rao.” A rollup reads up to 20 saved teammates at a time. If you have more, name the group you need.

Hereforth reads the latest update each teammate wrote in a standup thread they approved for you. It reports when a reachable teammate has no active thread you can read and when a teammate is unavailable. Ask separately to request access. Updates are returned to your connected assistant, and each teammate’s private library and other standup threads remain on their Mac.

## Broader sharing design

The following options extend the standup pilot to other shareable sources. Give each teammate a Hereforth connection in their own assistant. Once connected, they can ask about a person by name. The owner’s Mac searches the material that person has shared with the caller and returns dated evidence. Claude can answer and handle follow-ups in the same chat. A private browser page is an optional client of the same queries.

For example, the owner can publish “The launch is waiting on the localization review, as of Thursday” from a meeting that also covered personnel changes. A teammate asking about launch progress sees that update and can open the approved note. The owner can follow a private reference back to the original meeting. This gives the teammate something useful even when sharing the full transcript would be inappropriate.

## What can be shared

For a recurring status sync, publish a dated update with changes since the previous edition, blockers, and decisions awaiting an owner. Give readers a link to the approved revision. Follow-ups can reuse the published evidence, and unanswered questions can become the agenda if the team still needs to meet. [Check-in pilot and outcome measures](plan.md#replacing-routine-status-syncs)

For a task still underway, the owner can grant named recipients access to its live status. Preview the exact public-facing title and the state fields that can change automatically. Free-text progress, source links, and new blockers each require explicit sharing. Recheck the viewer's grant before each live update and when serving lists, counts, or follow-up answers. [Agent activity on Home](plan.md#what-my-agents-are-working-on)

| Option | What the teammate gets | When it fits |
| --- | --- | --- |
| Owner-reviewed note | The exact text, display title, date, and audience the owner previewed. Its citation opens this version of the note. | Start here for progress updates, decisions, and answers derived from personal chats. The owner can revise or expire a stale update. |
| Selected source or excerpt | Searchable evidence and a link to the passages the recipient can read. | Add for project documents intended for collaboration. Check the source system's permissions and the owner's sharing grant. When upstream access cannot be established, keep the imported transcript private. |
| Synchronized team index | A team service can answer while the Mac sleeps. | Consider if uptime becomes important. Copies introduce another store for ACL changes, deletion, and retention. Start by measuring how often teammates actually encounter an offline Mac. |

Indalbo provides a precedent for owner-defined sharing rules and a record of each disclosure. Onyx documents source-permission synchronization for its enterprise connectors. OpenClaw's Session Share documents explicit cross-gateway sharing of selected sessions. The proposed first release borrows the owner controls and keeps the shareable unit small enough to preview. [Indalbo](https://indalbo.com/) · [Onyx connectors](https://docs.onyx.app/overview/core_features/connectors) · [OpenClaw Session Share](https://docs.openclaw.ai/plugins/session-share)

## Ways to reach the Mac

| Client | Identity and deployment | Trade-off |
| --- | --- | --- |
| Tailnet browser | Tailscale Serve terminates HTTPS and proxies to a loopback-only listener. On first use the owner invites the person and confirms a Hereforth account bound to their verified identity. Require a revocable app session on subsequent requests. Serve supplies user headers for user-owned devices and strips incoming copies. | Optional browser access for a small team already on Tailscale. Network access only establishes reachability. Reject missing identity on the teammate path, including tagged-device requests. A loopback client can supply its own headers, so require the app credential as well. [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve) |
| Ordinary LAN | Offer a paired native client over TLS. The Mac displays a short-lived, single-use invite and server fingerprint in a QR code. The client verifies the server, proves possession of its device key, and the owner associates the device with a person. | Works without a tailnet account. Requires onboarding per device. Bonjour can advertise the service address. Pairing provides identity. [Apple Bonjour](https://developer.apple.com/documentation/network/bonjour) |
| A teammate's assistant via MCP | Offer scoped search and citation tools over authenticated HTTP. Bind each request to the verified subject and check audience, expiry, and scope. Use the same per-item grants as the browser. A local MCP client on the teammate's machine can reach the private service over their network. | Primary client. Offer a privately routed connection for local clients and a specifically enabled, externally reachable MCP gateway for hosted Claude, whose connector originates from Anthropic infrastructure. A private tailnet URL alone cannot serve it. Returning excerpts to an MCP client also lets that client send them to its own model provider. [MCP authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization) · [Claude connector networking](https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp) |
| Slack DM | Socket Mode opens an outbound connection from the Mac. Bind the Slack workspace and user identity to the invited Hereforth account. Start with a private DM containing an authenticated link to the answer. | Reaches teammates where they work. Slack holds the question and anything posted in reply. Group channels and Slack Connect can include people with different source access. [Slack Socket Mode](https://docs.slack.dev/apis/events-api/using-socket-mode/) · [Slack Connect](https://docs.slack.dev/apis/slack-connect/) |

## How an answer is produced

1. **Publish.** On the Mac, the owner selects a project, previews the exact note, chooses named recipients, and optionally sets an expiry. Store a grant against the immutable note revision and record private provenance separately. Offer a private draft when the owner asks Hereforth to generate an update from a mixed conversation. The owner confirms they can share the material.
2. **Retrieve.** Resolve the caller from the authenticated session. In SQLite join active grants, current revisions, and matching passages before selecting the top results. Use this rule for snippets, titles, citation links and follow-up turns. A project name or shared URL alone gives no access. Each teammate conversation gets its own history. Owner Home, task transcripts, and global summaries may contain private details and stay outside that context.
3. **Answer.** For the first prototype, return dated matching passages directly. This validates usefulness and access rules without charging the owner's personal model plan. Later, pass only authorized excerpts to a model under a verified team billing arrangement or use an approved local model. When evidence is insufficient, say so and offer to send the question to the owner. The owner sees the requester and can publish a one-off answer.
4. **Deliver and revoke.** For generated answers, buffer the draft and recheck the grants for every contributing passage before releasing it. On each follow-up or citation open, check again. An edit creates a new revision for review. A source withdrawal invalidates its dependent notes and derived answers pending review. For the first implementation, omit cross-user answer caches. Previously delivered text can be retained by its recipient, Slack, or their model provider. Revocation governs future access through Hereforth.
5. **Handle requests for action.** “Can I get staging access?” can return the shared access policy and let the requester submit a request with a stable ID. The system that owns the entitlement checks eligibility and records the authorized approver's decision. Keep the teammate capability limited to asking, reading authorized evidence, and submitting requests. The owner's desktop-control tools and credentials belong to the owner session.

Show the owner a local activity record with the requester, time, cited revisions, delivery channel and any request disposition. Store just the identifiers needed to review a disclosure by default. Let the owner inspect effective access as a selected teammate before publishing.

## Feasibility and acceptance

The [SQLite experiment](experiments/teammate-access.sql) exercises two people asking about the same launch. Both can see one approved update, and only one can see a second. A private matching passage stays out of both result sets. The same grant relation covers a direct citation lookup. Revocation removes access for one person, and a changed revision needs a fresh grant. To reproduce from the repository root, run `sqlite3 :memory: < docs/experiments/teammate-access.sql`. Passing checks print one confirmation line.

The next experiment needs two real devices and synthetic project notes. Connect a colleague’s Claude, preview their grants, ask who is working on the launch, and follow a citation inside the same chat. Exercise both a local Claude Code client and a hosted Claude connector. Revoke access while a generated answer is pending and verify that delivery stops. Repeat with an expired invitation, a second user opening a copied citation, a stale note in chat history, a withdrawn source, and an offline Mac. Measure how often the approved updates alone answer the team’s questions before investing in whole-source sync.
