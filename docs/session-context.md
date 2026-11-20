# Send context to a teammate's active session

Both people install Hereforth and connect their own assistant. Ryan publishes a session with a short label such as **Release review**. Mohit's assistant can then address a suggestion to that session. Ryan sees the sender and exact text in his Mac app and can allow or decline it. The receiving assistant collects approved context when it checks or while it is waiting for an offer. A sender cannot start a turn, see Ryan’s conversation, or operate his computer.

## Pair two installations

These commands configure one direction, from Mohit to Ryan. On each Mac, set a shell variable for the installed helper:

```sh
hf="$HOME/Applications/Hereforth.app/Contents/MacOS/hereforth"
```

1. On Ryan’s Mac, run `"$hf" peer serve` and leave the process running. It listens on `127.0.0.1:9124`. For two Macs, use a private HTTPS reverse proxy reachable by both, such as Tailscale Serve. For example, on an available tailnet HTTPS port, `tailscale serve --bg --https=9443 http://127.0.0.1:9124` prints the private address. Use your own tailnet access rules. [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve)
2. In another terminal on Ryan’s Mac, run `"$hf" peer invite Mohit | pbcopy`. Give that credential and the private HTTPS address to Mohit through a trusted channel. Ryan’s installation uses the credential to associate incoming requests with the configured sender label.
3. On Mohit’s Mac, copy the invitation credential and run `pbpaste | "$hf" peer add Ryan https://ryan-mac.example.ts.net:9443`, substituting Ryan’s actual origin. Keep the credential out of assistant chats. Pair in the reverse direction if Ryan also wants to initiate requests.

Ryan can revoke this sender with `"$hf" peer revoke Mohit`. Mohit can delete the saved destination with `"$hf" peer remove Ryan`. Stopping the listener stops remote queries. The pilot uses locally named peers and per-sender credentials. Enterprise identity, policy routing, and an always-running managed receiver are later work.

## Try it from two assistants

1. **Ryan:** “Publish this Hereforth session as Release review.” The assistant gets a public routing ID and a private receiver key for this conversation. Only the ID and label appear in peer discovery. It can ask to wait for approved context if Ryan wants it to receive a suggestion during this turn.
2. **Mohit:** “Show me Ryan’s available Hereforth sessions.” Then: “Send Release review this context: Design confirmed Friday after Thursday’s accessibility review. Please use the revised date in our checklist.” The transport returns a request receipt. A retry should reuse the same request ID.
3. **Ryan:** In **Hereforth → Inbox**, inspect the sender, session, and full text. Choose **Add to Session** or **Decline**. After approval, a waiting session can collect the message. In an idle session, ask “Check for approved Hereforth context.” The assistant uses its private receiver key. Other published sessions cannot collect it.
4. **Mohit:** “Did my latest context request reach Ryan’s session?” Delivery status describes the text exchange. Any organizational decision, tool action, or ticket outcome needs its own evidence.

A session can unpublish itself. An inactive registration expires after 30 minutes without an authorized read. An ended or expired session requires a new offer to a newly chosen destination. The local inbox records the outcome. An owner can still prepare, edit, and export a Markdown draft independently.
