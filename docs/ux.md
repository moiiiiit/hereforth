# Designing Hereforth

Hereforth should be useful when its window is closed. A person asks their assistant what was decided, checks the evidence, and suggests context for a teammate’s existing session. Both use Hereforth. The Mac window lets each person choose their sources, inspect local records, and review what will enter their own session.

## Interaction principles

| Principle | How it shows up |
| --- | --- |
| Start with the question people ask | Give every information view an equivalent assistant query. “Which conversations have I imported?” and “Show me Priya’s handoff” should work in Claude or Codex. Keep the underlying IDs and results consistent across clients. |
| Put evidence next to decisions | Identify the source, speaker, and date when available. Let the reader open the exact passage. When Thursday was proposed and Friday was confirmed, show both in order and explain the change. Say when the evidence is missing or ambiguous. |
| Make sharing deliberate | Name the peer and the session before sending. Show the authenticated sender and exact text to the recipient before approval. Distinguish a pending request, approval awaiting collection, and delivery to the intended session. A declined request stays out of the assistant’s context. |
| Give each state a clear next action | An empty library offers import and explains which files work. A search with no matches offers a way to clear the filter. A draft opens ready to read, with editing and export within reach. A recoverable error preserves the user's work and explains what to try next. |
| Let each person keep their assistant | Use client-neutral labels. Mohit can send a decision and supporting evidence from Claude to a session Ryan published in Codex. Ryan decides whether the context belongs there. Approved text can suggest a next step. Responsibility for deciding and taking action stays with Ryan and his assistant. |
| Respect attention and access | Keep drafts and changes discoverable without moving someone's selection while they work. Use native keyboard focus, named controls, selectable evidence, and macOS light, dark, and increased-contrast appearances. Pair color-coded cues with text or shape. |
| Leave room for unfamiliar work | Accept a plain-language request. Ask for the detail the next person needs. A vendor review and a temporary data access request can share a personal work queue. Each goes to someone with authority to decide it. [Workplace scenarios](workplace-requests.md) |
| Let the queue do the bookkeeping | A named session can end while a person still owns a request. Keep workplace requests in the person’s queue. Let their assistant categorize them. Let the receiver inspect and approve the effect, then record its outcome automatically. Show **Fulfilled** only when the system can substantiate it. |
| Give standup questions their own thread | Let a teammate find an existing approved thread by person. Opening a new one requires the owner to review its exact first update. Date and attribute replies, retain the exchange across assistant chats, and offer to ask the owner when the information shared so far is insufficient. [Walk through a standup](teammate-knowledge.md#ask-for-someones-standup) |
| Sound like the person doing the work | Run Humanizer in the composing assistant for standups, replies, requests, summaries, and handoffs. Read the owner's voice notes before drafting. A short ask can be one sentence. If the owner gave a recommendation, keep their reasoning and level of certainty. Preserve authored wording supplied for verbatim delivery, quotations, code, and receipts. |

## Visual language

Use the [Hereforth mark](../Assets/Hereforth.png) for the app icon and first-run identity. It should also work at Finder sidebar size. Keep the macOS type hierarchy, system materials, and native control behavior. Use evergreen as a restrained accent, with a lighter tint on dark surfaces. Let the title, recipient, and quoted evidence carry the hierarchy. Long briefs need a comfortable reading width and a distinct editing surface. Reserve monospaced text for Markdown editing, code, and identifiers.

## Check a change in use

Use two isolated libraries and the [Juniper conversations](../Examples/Juniper). Check an empty import, a populated library, a filter with no matches, and a long draft. Edit the draft, switch away and back, and compare the export with the reviewed text. Send context between paired profiles and check the recipient’s pending, declined, approved, and delivered states, including a second session that should receive nothing. For a UI change, check keyboard navigation, accessible control names, and both appearances at a compact window width.
