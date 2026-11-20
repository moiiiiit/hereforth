<img src="Assets/Hereforth.png" width="88" height="88" alt="Hereforth app icon">

# Hereforth

Hereforth is a free, MIT-licensed personal assistant for macOS. Ask your own Claude or Codex what you decided across chats. Connect with a teammate’s Hereforth to send context to a named session or leave a request for them to review at their desk. Each person’s Mac holds their own library. The connected assistant supplies the model.

## Install

From this checkout on a Mac running macOS 14 or later with the Apple Command Line Tools and Swift 5.9 or later, run:

```sh
./scripts/install.sh --claude-desktop --claude-code
open ~/Applications/Hereforth.app
```

Use either connection flag on its own if you use just one client. Running the installer without flags installs the app and its local MCP helper. The installer builds from source for your Mac and installs into your own Applications folder. Fully quit and reopen Claude Desktop when convenient, or start a fresh Claude Code session. On a managed Mac, your organization's installation and local connector settings apply. [Claude Desktop local connectors](https://modelcontextprotocol.io/quickstart/user) · [Claude Code MCP](https://code.claude.com/docs/en/mcp)

To connect an installed Codex CLI to the same local helper, run this once and start a fresh Codex session:

```sh
codex mcp add hereforth -- "$HOME/Applications/Hereforth.app/Contents/MacOS/hereforth" mcp
```

## Try a decision and a handoff

1. Open **Hereforth → Import Files**. Select both JSON files in [Examples/Juniper](Examples/Juniper), or your own extracted Claude or ChatGPT conversation JSON, UTF-8 text, or Markdown. Hereforth imports the conversations in each selected file. [Claude exports](https://support.claude.com/en/articles/9450526-export-your-claude-data) · [ChatGPT exports](https://help.openai.com/en/articles/7260999-exporting-your-chatgpt-history-and-data)
2. Ask Claude or Codex **“Use Hereforth. What did we decide about the Juniper launch? Check both chats and explain what changed.”** One conversation proposes Thursday. A later one confirms Friday. Ask to see the dated passages.
3. For a direct handoff, [pair both Hereforth installations](docs/session-context.md). Ryan can say **“Publish this Hereforth session as Release review.”** From your assistant, ask **“Send the launch decision and reason to Ryan’s Release review session.”** Ryan reviews the text in his Inbox. A waiting session can receive it on approval, or Ryan can ask it to check. The sender can ask whether the context was delivered.
4. For something Ryan should handle later, ask **“Send Ryan a work request for seven days of read-only access to the Juniper Hereforth brief.”** The request goes to his personal queue even when he has no published assistant session. Hereforth runs a supported grant after his review and records the result. [Workplace request flows and current capabilities](docs/workplace-requests.md)

You can also ask **“Which chats have I imported?”** or **“Show me the local draft I prepared for Ryan.”** Local drafts can be edited and exported as Markdown. Search matches words in titles and passages. Returned material can reach the assistant’s model provider. The local MCP helper works with the app window closed. Peer delivery also needs the recipient’s peer service to be reachable.

To import a single Claude Code chat, run `/export discussion.txt` inside that chat and select the file in Hereforth. Text imports preserve the transcript as written. Provider JSON also supplies structured speakers and timestamps. [Claude Code export command](https://code.claude.com/docs/en/commands)

The default library is in `~/Library/Application Support/Hereforth/`. To load the sample into that library from a terminal, run:

```sh
helper="$HOME/Applications/Hereforth.app/Contents/MacOS/hereforth"
"$helper" import Examples/Juniper/*.json
```

## Development

```sh
swift test
swift build
python3 Tests/smoke-mcp.py .build/debug/hereforth
python3 Tests/peer-smoke.py .build/debug/hereforth
```

The [UX guide](docs/ux.md) and [agent instructions](AGENTS.md) cover interaction design and verification. The [implementation plan](docs/plan.md) also covers connected teammate questions, a live team standup, blocker replies, and following a decision when it changes. The [product assessment](docs/product-assessment.md) compares Comity and other tools and links the proposed features to public requests. The [integration research](docs/research.md), [sharing design](docs/teammate-knowledge.md), [remote control design](docs/remote-control.md), and [usage and power controls](docs/availability-and-usage.md) describe later work.

[MIT license](LICENSE)
