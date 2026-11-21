<img src="Assets/Hereforth.png" width="88" height="88" alt="Hereforth macOS app icon">

# Hereforth

I want to ask Claude what we decided last week, even if we made the decision in ChatGPT. If Ryan is picking up the work, I want to send him the answer in Codex. Neither of us should have to dig up three chats or book a sync just to find out why the date moved.

Hereforth is an open-source personal assistant for macOS. It keeps one searchable library of your imported chats on your Mac. Claude, Codex, and Kimi Code can ask that library questions through a local Model Context Protocol (MCP) server. If you run an open-weight model, you can connect a tool-capable client like OpenCode or LM Studio. Hereforth doesn’t need its own model account or API key. [Connect your assistant](docs/install.md)

## Install

**[Download Hereforth for Apple Silicon](https://github.com/moiiiiit/hereforth/releases/latest/download/Hereforth.dmg)** · macOS 14 or later

1. Open the DMG, drag **Hereforth** into **Applications**, then open it from there.
2. Choose **Hereforth → Connect Assistants…** and pick the assistant you use.
3. Start a fresh chat. For Claude Desktop, quit and reopen it first.

The DMG includes the app, the MCP helper, and the updater. You don’t need Xcode or the Command Line Tools. While Hereforth is running, it can check for signed updates. You can change that in **Hereforth → Settings** or choose **Check for Updates…** yourself. If you prefer to build from a signed source release, there’s a separate installer. [Install and update options](docs/install.md)

## Try it with two chats

Open **Import Files** in Hereforth and select both JSON files from the [Juniper example](Examples/Juniper). In a new Claude or Codex chat, ask this question.

> What did we decide about the Juniper launch? Use Hereforth and show me where the date changed.

One chat proposes Thursday. The other confirms Friday. You can ask to see both dated passages and check the answer yourself.

For your own work, import the conversation JSON from a Claude or ChatGPT export. Hereforth also reads Markdown and plain text, including a single Claude Code chat saved with `/export discussion.txt`. Provider exports carry dates and speakers. Plain text keeps what was written in the file. [Claude exports](https://support.claude.com/en/articles/9450526-export-your-claude-data) · [ChatGPT exports](https://help.openai.com/en/articles/7260999-exporting-your-chatgpt-history-and-data)

## Hand the decision to a teammate

Each teammate installs Hereforth and pairs with the people they need to reach over a private network, such as Tailscale. The receiving Mac needs to be reachable. What you send depends on whether Ryan is already working on it. [Pair with teammates](docs/session-context.md#pair-teammates)

- **Ryan already has a chat open.** He asks his assistant to publish a session called *Release review*. In your own assistant, say “Send Ryan’s Release review session the Friday decision and why it changed.” Ryan sees the exact text in his Inbox. Once he approves it, his assistant can pick it up. You can ask yours whether it arrived.
- **You need something from Ryan.** Ask “Can I get seven days of read-only access to Ryan’s Juniper brief?” It goes in his **Work Requests** even if all his chats are closed. He chooses the brief, reviews the version you’ll see, and approves. Hereforth grants access to that copy and records the result. IT, security, and vendor requests can go through the same queue. Granting access in an external system still needs an integration with that system. [Work requests](docs/workplace-requests.md)

## Skip a status meeting

Ask your assistant “What did I work on this week, and what’s still open?” It can pull dated passages from your imported chats. You decide which of those details to put in a standup.

On the other side, Ryan can ask his Claude “What’s Mohit working on?” The first time, he can request your standup. You review the request and write the opening update. Approval creates a Hereforth thread just for the two of you. Ryan can read it from Codex tomorrow, ask what’s blocked, or leave a follow-up. His access lasts seven days, and you can revoke it earlier. Your original chats stay in your own library. [Standup walkthrough](docs/teammate-knowledge.md#ask-for-someones-standup)

Once you’ve paired with your teammates, ask “Give me the team standup from Hereforth.” It can read the latest update each teammate has shared with you, for up to 20 people at a time. Ask for dates and whose update is missing. [Read a team standup](docs/teammate-knowledge.md#read-a-team-standup)

## Use it from your phone

When I’m away from my Mac, I can check what my published agents are working on, approve a request, and send Ryan a brief. The phone page runs on my Mac behind Tailscale. If I need to use the desktop myself, I can open my saved screen-sharing connection from the same page. [Set up Phone Access](docs/remote-control.md)

## Leaving your Mac at your desk

I like being able to close the Hereforth window and still let someone read my standup. Click the **h** in the menu bar and choose **Keep Awake for 1 Hour**. In **Keep Awake**, you can set a different duration, let the display sleep, or turn on periodic pointer movement while the Mac is idle.

To see how much Claude Code, Codex, and Kimi Code ran on this Mac, open **Usage** and click **Load usage**, or ask your assistant “What was my model usage this week?” It reads the counts in your local logs when you ask. [Power and usage](docs/availability-and-usage.md)

## What stays on your Mac

Your library lives in `~/Library/Application Support/Hereforth/`. Local searches work with the Hereforth window closed. When you ask a hosted assistant a question, the passages it retrieves can go to that assistant’s model provider. A teammate sees the update, brief, or message you share with them. A copy they already read may still be in their chat history.

Hereforth uses Humanizer by default for handoffs, requests, replies, and standups. To set your own voice, put a few lines about how you write in a text file and run the commands below. If you give your assistant exact words to send, it should use them as written. [Humanizer](https://github.com/blader/humanizer)

```sh
helper="/Applications/Hereforth.app/Contents/MacOS/hereforth"
"$helper" voice set < my-writing-notes.txt
"$helper" voice show
```

Use `"$helper" voice clear` to go back to the default. Your voice notes stay in your library and are available to your connected assistant when it drafts a message.

## Why an open-source Comity alternative?

I like being able to hand work from one person’s coding agent to another. Comity’s *Ask my agent* can answer from a read-only copy of a recent session. With Hereforth, I wanted Ryan to get the part he needs and have somewhere to follow up, while I keep the original session private. That’s why a standup opens its own thread. There’s no Hereforth account or team subscription to set up. [Comity handoffs](https://comity.so/docs/collaboration/handoffs) · [Ask my agent](https://comity.so/docs/collaboration/ask-my-agent) · [Product comparison](docs/product-assessment.md)

## Development

From a checkout, run `./scripts/install.sh` to build a local app. To exercise the library, MCP tools, and handoffs with paired teammates, run these checks.

```sh
swift test
swift build
python3 Tests/smoke-mcp.py .build/debug/hereforth
python3 Tests/peer-smoke.py .build/debug/hereforth
python3 Tests/twenty-peer-smoke.py .build/debug/hereforth
```

The roadmap covers live agent activity, team-hours schedules, and project-level usage reporting. [Implementation plan](docs/plan.md) · [Power and usage](docs/availability-and-usage.md) · [Integration research](docs/research.md) · [Remote access design](docs/remote-control.md)

[UX guide](docs/ux.md) · [Contributor instructions](AGENTS.md) · [Release process](docs/releases.md) · [MIT license](LICENSE)
