# Working on Hereforth

Hereforth is a local macOS assistant with a SwiftUI app and a stdio MCP helper. Both teammates install Hereforth for connected work. The sender addresses a context suggestion to a session the recipient has chosen to publish. The recipient reviews it on their own Mac. Use the [UX design guide](docs/ux.md) when adding or reviewing any interaction.

## UX agreements

- Use Humanizer by default for communication the assistant writes through Hereforth. Fetch the current owner's voice notes when drafting. Apply the embedded rewrite before presenting or sending the draft. Keep names, numbers, attribution, uncertainty, and the exact text of quotations intact. A request to send specific wording takes precedence. Copy the approved bytes on delivery. Keep each person's voice sample and preferences out of shared fixtures and release defaults.
- Give each information view an equivalent natural-language query. Keep the window and MCP results grounded in the same store, source IDs, and reviewed text.
- Show where a decision came from. Preserve dates, uncertainty, and the difference between a proposal and a confirmed decision.
- Keep local drafts, incoming requests, approvals, and session delivery distinct. Show the authenticated sender, named session, and exact proposed text. Require the recipient’s approval before their assistant can read any of it. Receiving context grants no execution or computer-control capability. Keep Markdown export a local utility.
- Use native Mac controls with accessible names and keyboard access. Support light and dark appearances. Give empty, filtered, and error states an actionable next step.
- Let a person describe an IT issue, security review, data-access need, vendor request, or unfamiliar task in their own words. Ask only for missing details that affect the route or decision. Attribute organizational approvals and fulfillment to the system that owns them. See [workplace requests](docs/workplace-requests.md).
- A personal request belongs to its recipient even when all their chats close. Categories help triage. Bind each executable approval to the exact resource, recipient, scope, and expiry. Close the request automatically only after the authorized effect has a receipt. Keep a retry from granting twice.
- A teammate asking what someone is working on should discover their approved Hereforth standup thread. Open a fresh, recipient-scoped thread on approval. Start with the exact update the owner approved. Private weekly evidence, provider conversations, and source handles stay in the owner's library. Check access on discovery, reads, and replies.
- Ground “this week” in original passage timestamps and the owner's local calendar. Keep undated material discoverable in the library. Return bounded excerpts with stable citations, cover quieter conversations, and tell the assistant when more evidence is available.
- Use the shared mark and a restrained evergreen accent. Favor one primary action per state. Use client-neutral language in shared workflows.

## Verification

Run `swift test` for store and import changes. Run `swift build` and `python3 Tests/smoke-mcp.py .build/debug/hereforth` when changing tools or handoffs. Use `python3 Tests/peer-smoke.py .build/debug/hereforth` for two-profile routing, approvals, fulfillment, and revocation. For app changes, build the installed bundle and exercise the affected flow with synthetic inputs in a temporary `HEREFORTH_HOME`. Preserve the owner's real library and existing assistant registrations during tests. Document which client and data you actually verified.
