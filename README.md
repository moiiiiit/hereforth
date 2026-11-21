<img src="Assets/Hereforth.png" width="88" height="88" alt="Hereforth macOS app icon">

# Hereforth

Hereforth is an open-source, local-first AI assistant for macOS. Import your ChatGPT and Claude conversations, then ask Claude Code, Claude Desktop, or Codex what you decided across chats. Hereforth runs a local Model Context Protocol (MCP) server and keeps the searchable library on your Mac. Your connected assistant supplies the model.

Ask **“What did we decide about the launch?”** to get the dated passages. Ask **“What is Ryan working on?”** to read a standup he shared with you. You can follow up in the same Hereforth thread tomorrow, even if you switch assistants.

## Install

On macOS 14 or later, install the Apple Command Line Tools if needed with `xcode-select --install`. The installer verifies the signed release and builds the app for your Mac. To install Hereforth and connect Claude Code:

```sh
curl -fL --proto '=https' https://github.com/moiiiiit/hereforth/releases/latest/download/install.sh -o hereforth-install.sh
/bin/bash hereforth-install.sh --claude-code
open ~/Applications/Hereforth.app
```

Choose `--claude-code`, `--claude-desktop`, or `--codex` for the assistants you use. You can combine the flags or omit them to install just the app and helper. Open a new assistant chat after connecting. For Claude Desktop, fully quit and reopen the app. On managed Macs, your organization's installation and local connector settings apply. [Installation and signature verification](docs/install.md) · [Read the installer](scripts/bootstrap.sh) · [Release notes](https://github.com/moiiiiit/hereforth/releases/latest)

Release installs check daily for signed updates. To check now or turn automatic updates off:

```sh
helper="$HOME/Applications/Hereforth.app/Contents/MacOS/hereforth"
"$helper" update check
"$helper" update disable
```

Use `update install` to apply an available update, `update enable` to resume daily updates, or `update status` to see the setting.

To connect an installed Codex CLI to the same local helper, run this once and start a fresh Codex session:

```sh
codex mcp add hereforth -- "$HOME/Applications/Hereforth.app/Contents/MacOS/hereforth" mcp
```

## An open-source Comity alternative for agent handoffs

Comity supports passing work between coding agents. Its *Ask my agent* feature can use a read-only copy of a teammate's recent agent session to answer questions. Hereforth takes a different approach to the same handoff. The recipient approves an opening update for a new standup thread. Both people can ask and answer there from their own assistants. The original sessions stay private. [Comity handoffs](https://comity.so/docs/collaboration/handoffs) · [Comity Ask my agent](https://comity.so/docs/collaboration/ask-my-agent)

Hereforth fits a Mac team that wants cross-chat memory, async standups, and direct peer connections without a Hereforth account or team subscription. Both teammates install the app, pair their Macs, and use a private network such as Tailscale. Each person can revoke a grant. Searching a private library works with the app window closed. A peer's Mac must be reachable for shared reads and requests. [How sharing works](docs/teammate-knowledge.md) · [Product comparison and scope](docs/product-assessment.md)

## Try a decision and a handoff

1. Open **Hereforth → Import Files**. Select both JSON files in [Examples/Juniper](Examples/Juniper), or your own extracted Claude or ChatGPT conversation JSON, UTF-8 text, or Markdown. Hereforth imports the conversations in each selected file. [Claude exports](https://support.claude.com/en/articles/9450526-export-your-claude-data) · [ChatGPT exports](https://help.openai.com/en/articles/7260999-exporting-your-chatgpt-history-and-data)
2. Ask Claude or Codex **“Use Hereforth. What did we decide about the Juniper launch? Check both chats and explain what changed.”** One conversation proposes Thursday. A later one confirms Friday. Ask to see the dated passages.
3. For a direct handoff, [pair both Hereforth installations](docs/session-context.md). Ryan can say **“Publish this Hereforth session as Release review.”** From your assistant, ask **“Send the launch decision and reason to Ryan’s Release review session.”** Ryan reviews the text in his Inbox. A waiting session can receive it on approval, or Ryan can ask it to check. The sender can ask whether the context was delivered.
4. For something Ryan should handle later, ask **“Send Ryan a work request for seven days of read-only access to the Juniper Hereforth brief.”** The request goes to his personal queue even when he has no published assistant session. Hereforth runs a supported grant after his review and records the result. [Workplace request flows and current capabilities](docs/workplace-requests.md)

You can also ask **“Which chats have I imported?”** or **“Show me the local draft I prepared for Ryan.”** Local drafts can be edited and exported as Markdown. Search matches words in titles and passages. Returned material can reach the assistant’s model provider. The local MCP helper works with the app window closed. Peer delivery also needs the recipient’s peer service to be reachable.

To import a single Claude Code chat, run `/export discussion.txt` inside that chat and select the file in Hereforth. Text imports preserve the transcript as written. Provider JSON also supplies structured speakers and timestamps. [Claude Code export command](https://code.claude.com/docs/en/commands)

## Ask for a teammate’s standup

1. After [pairing both Macs](docs/session-context.md), ask your assistant **“Ask Ryan for his standup so I can plan the docs review.”** Ryan can receive the request with all his assistant chats closed.
2. Ryan opens **Work Requests** and writes the update he wants to share. On approval, Hereforth creates a new, two-person thread with those exact words as the opening message. The grant lasts seven days and Ryan can revoke it earlier.
3. From a fresh Claude or Codex chat, ask **“What did Ryan say is blocked?”** Your assistant can find the thread, read the dated updates, and answer. If the information is missing, say **“Ask Ryan in that thread.”** His reply stays with the original update. [Standup walkthrough](docs/teammate-knowledge.md#ask-for-someones-standup)

For your own standup, ask **“Which conversations contributed to my work this week? What changed, and what's still open?”** Hereforth uses timestamps inside imported chats and a Monday-start week in your Mac's time zone. Undated text remains searchable in the library. You choose what to share from that evidence.

## Write in your own voice

Hereforth asks the connected assistant to use Humanizer when it drafts a request, standup, reply, summary, or handoff. The connector includes the writing guide for clients without the plugin. For a message like **“Send exactly: Docs review is done.”**, the assistant passes on the words you supplied. Hereforth delivers the same text you reviewed.

To personalize the default, put a few notes about how you write in a text file. For example, “Lead with what I need. When I recommend something, say why. Keep a quick question to one line.” Set those notes on your Mac with the installed helper:

```sh
helper="$HOME/Applications/Hereforth.app/Contents/MacOS/hereforth"
"$helper" voice set < my-writing-notes.txt
"$helper" voice show
```

`"$helper" voice clear` restores the general writing style. Your voice notes live in your local library. Your connected assistant can read them when it composes a message. Teammates receive the message you share. [Humanizer](https://github.com/blader/humanizer)

The default library is in `~/Library/Application Support/Hereforth/`. To load the sample into that library from a terminal, run:

```sh
helper="$HOME/Applications/Hereforth.app/Contents/MacOS/hereforth"
"$helper" import Examples/Juniper/*.json
```

## Development

For a local build from a repository checkout, run `./scripts/install.sh`. To run the tests:

```sh
swift test
swift build
python3 Tests/smoke-mcp.py .build/debug/hereforth
python3 Tests/peer-smoke.py .build/debug/hereforth
```

The [UX guide](docs/ux.md) and [agent instructions](AGENTS.md) cover interaction design and verification. The [implementation plan](docs/plan.md) also covers connected teammate questions, a live team standup, blocker replies, and following a decision when it changes. The [product assessment](docs/product-assessment.md) compares Comity and other tools and links the proposed features to public requests. The [integration research](docs/research.md), [sharing design](docs/teammate-knowledge.md), [remote control design](docs/remote-control.md), and [usage and power controls](docs/availability-and-usage.md) describe later work.

[MIT license](LICENSE)
