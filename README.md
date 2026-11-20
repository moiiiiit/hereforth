# Hereforth

Hereforth is a personal assistant for macOS. Ask Claude what you decided across conversations, check the original passages, and hand the work to someone in their own assistant. Your Mac keeps the library. Claude supplies the model. Hereforth is free, MIT-licensed, and runs without a Hereforth account, API key, or hosted service.

## Install

From this checkout on a Mac running macOS 14 or later with the Apple Command Line Tools and Swift 5.9 or later, run:

```sh
./scripts/install.sh --claude-desktop --claude-code
open ~/Applications/Hereforth.app
```

Use either connection flag on its own if you use just one client. Running the installer without flags installs the app and its local MCP helper. The installer builds from source for your Mac and installs into your own Applications folder. Fully quit and reopen Claude Desktop when convenient, or start a fresh Claude Code session. On a managed Mac, your organization's installation and local connector settings apply. [Claude Desktop local connectors](https://modelcontextprotocol.io/quickstart/user) · [Claude Code MCP](https://code.claude.com/docs/en/mcp)

## Try a decision and a handoff

1. Open **Hereforth → Import Files**. To try the example, select both JSON files in [Examples/Juniper](Examples/Juniper). For your own work, choose the extracted conversation JSON from a Claude or ChatGPT data export, or a UTF-8 Markdown or text transcript. The JSON picker imports the conversations in each selected file. [Claude exports](https://support.claude.com/en/articles/9450526-export-your-claude-data) · [ChatGPT exports](https://help.openai.com/en/articles/7260999-exporting-your-chatgpt-history-and-data)
2. In Claude Desktop or Claude Code, ask **“Use Hereforth. What did we decide across chats about the Juniper launch? Check the sources and explain what changed.”** The sample starts with a proposed Thursday launch. A later conversation confirms Friday, November 13, so Design can complete its accessibility review. Ask Claude to read either cited passage.
3. Say **“Prepare a Hereforth handoff for Priya with the decision, why it changed, and the next step.”** Claude gets the Markdown and Hereforth saves a private draft. Open it under **Draft briefs**, review the actual text and excerpts, and choose **Save Markdown**. You can also review and copy the returned Markdown in Claude.
4. Send the reviewed brief through a channel you already use. Priya attaches it to Claude, ChatGPT, Cursor, or another assistant and asks **“Pick this up. What was agreed, and what do I do first?”** The brief includes the selected evidence so she can continue while your Mac is asleep. She can use it without installing Hereforth.

You can also ask “Which conversations have I imported?” or “Show me the handoff I prepared for Priya.” The local connector exposes `list_conversations`, `search_decisions`, `read_passage`, `prepare_handoff`, and `get_handoffs`. It works with the app window closed. Existing web chats enter the library through a file you select. Search matches words in conversation titles and passages, and Claude interprets the returned evidence. A returned passage can reach the model provider through the Claude client. The draft's recipient is a label for your review. You control delivery, and a delivered file stays with its recipient.

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
```

The [implementation plan](docs/plan.md) also covers connected teammate questions, a live team standup, blocker replies, and following a decision when it changes. The [product assessment](docs/product-assessment.md) compares Comity and other tools and links the proposed features to public requests. The [integration research](docs/research.md), [sharing design](docs/teammate-knowledge.md), [remote control design](docs/remote-control.md), and [usage and power controls](docs/availability-and-usage.md) describe later work.

[MIT license](LICENSE)
