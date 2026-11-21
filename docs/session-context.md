# Send context to a teammate's active session

Both people install Hereforth and connect their own assistant. Ryan publishes a session with a short label such as **Release review**. Mohit's assistant can then address a suggestion to that session. Ryan sees the sender and exact text in his Mac app and can allow or decline it. The receiving assistant collects approved context when it checks or while it is waiting for an offer. A sender cannot start a turn, see Ryan’s conversation, or operate his computer.

## Pair teammates

[Install Hereforth and connect your assistant](install.md) on each Mac. Open Terminal and set `hf` to the helper in the app you installed. This example uses the standard location for the disk image.

```sh
hf="/Applications/Hereforth.app/Contents/MacOS/hereforth"
```

If you installed to the Applications folder in your home folder, set `hf="$HOME/Applications/Hereforth.app/Contents/MacOS/hereforth"` instead. The signed-source installer uses this location.

This example lets Mohit initiate requests to Ryan.

1. On Ryan’s Mac, start `"$hf" peer serve` and leave it running. It listens on `127.0.0.1:9124`. Set up one private HTTPS origin for this receiver. For example, `tailscale serve --bg --https=9443 http://127.0.0.1:9124` uses an available HTTPS port on Ryan’s tailnet. Apply your tailnet’s access rules to limit reachability to the team. [Tailscale Serve CLI](https://tailscale.com/docs/reference/tailscale-cli/serve)
2. In a second Terminal window on Ryan’s Mac, set `hf` again and run `"$hf" peer invite Mohit | pbcopy`. Share the credential privately with Mohit along with Ryan’s HTTPS origin. Ryan’s copy uses the credential to identify Mohit, so issue a separate invitation for each sender and keep credentials out of assistant chats.
3. On Mohit’s Mac, copy the credential and run `pbpaste | "$hf" peer add Ryan https://ryan-mac.example.ts.net:9443`, using Ryan’s actual origin. Choose distinct labels such as full names when two people share a first name. Use those labels when addressing teammates from your assistant.

For a team standup, repeat this pairing from the organizer to each teammate whose update they need. Each receiving Mac uses one listener and one HTTPS origin for all authorized senders. Pair in the reverse direction if a teammate also needs to start their own requests. The receiving Mac must be reachable and the listener running for remote queries.

Ask your assistant “Which teammates have I saved in Hereforth?” or run `"$hf" peer list`. Add a search term to filter the saved labels, for example `"$hf" peer list "Ryan"`. Use the displayed label if a name is ambiguous.

Ryan can revoke Mohit’s credential with `"$hf" peer revoke Mohit`. Mohit can remove the saved destination with `"$hf" peer remove Ryan`. Running `peer invite` again with the same sender label replaces the credential. The new credential requires fresh approvals.

## Try it from two assistants

1. **Ryan:** “Publish this Hereforth session as Release review.” The assistant gets a public routing ID and a private receiver key for this conversation. Only the ID and label appear in peer discovery. It can ask to wait for approved context if Ryan wants it to receive a suggestion during this turn.
2. **Mohit:** “Show me Ryan’s available Hereforth sessions.” Then: “Send Release review this context: Design confirmed Friday after Thursday’s accessibility review. Please use the revised date in our checklist.” The transport returns a request receipt. A retry should reuse the same request ID.
3. **Ryan:** In **Hereforth → Inbox**, inspect the sender, session, and full text. Choose **Add to Session** or **Decline**. After approval, a waiting session can collect the message. In an idle session, ask “Check for approved Hereforth context.” The assistant uses its private receiver key. Other published sessions cannot collect it.
4. **Mohit:** “Did my latest context request reach Ryan’s session?” Delivery status describes the text exchange. Any organizational decision, tool action, or ticket outcome needs its own evidence.

A session can unpublish itself. An inactive registration expires after 30 minutes without an authorized read. An ended or expired session requires a new offer to a newly chosen destination. The local inbox records the outcome. An owner can still prepare, edit, and export a Markdown draft independently.
