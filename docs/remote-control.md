# Hereforth from your phone

The phone page connects to Hereforth on your Mac. Use it to check agent activity, review an incoming request, or send the Juniper brief to Ryan’s published session. The Mac must be awake and reachable. You can close the Hereforth window while the listener runs.

## Pair your phone

1. Connect the Mac and phone to Tailscale. In the Tailscale app, find the Mac’s full DNS name and the login that owns your phone. Use a personally signed-in phone. Tailscale Serve supplies the signed-in user’s identity to Hereforth. A teammate needs their own Hereforth pairing for shared work.
2. Open **Phone Access** in Hereforth on your Mac. Pick an unused HTTPS port for this service. The examples use 9444 for the phone’s HTTPS connection and 9125 for the local receiver. Check existing routes with `tailscale serve status`.
3. In Terminal, configure the installed helper with your own Mac name and Tailscale login. Then click **Start Listener** in Hereforth.

   ```sh
   helper="/Applications/Hereforth.app/Contents/MacOS/hereforth"
   "$helper" phone configure https://your-mac.example.ts.net:9444 owner@example.com 9125
   ```

4. Run the following commands on the Mac. Serve publishes that loopback listener inside your tailnet. If Tailscale asks you to enable HTTPS, complete its setup. The second command displays a one-time pairing code on the Mac.

   ```sh
   tailscale serve --bg --https=9444 http://127.0.0.1:9125
   "$helper" phone pair
   ```

5. On the phone, open the HTTPS address you configured, enter the code, and create a passkey. Save the page to your Home Screen or bookmarks. Hereforth checks the tailnet identity and the passkey. A passkey may sync with the owner’s other devices through their password manager. [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve)

If you installed Hereforth in your home Applications folder, use that path for the helper. To take the phone view offline, stop the listener in **Phone Access**. Use `"$helper" phone status` to list enrolled passkeys and sessions. To sign out all sessions, use `"$helper" phone revoke all`. To remove a lost phone’s credential and its sessions, use `"$helper" phone revoke-passkey PASSKEY_ID`. Use `revoke-passkey all` to require enrollment again on every phone. To remove the dedicated Serve route, use `tailscale serve --https=9444 off`. [Serve CLI](https://tailscale.com/docs/reference/tailscale-cli/serve)

## Check activity, approve a request, or hand off work

- **See what’s happening.** Publish a session from the assistant you want to track. For example, ask “Publish this Hereforth session as Juniper launch review and report progress.” The phone shows the label and last confirmed contact. When you opt in to progress updates, the assistant can report a private task summary and whether it’s running, waiting, or done. You can ask your assistant “What are my Hereforth agents working on?” for the same view. A connected session can be waiting for you even while its connection is healthy.
- **Review a request.** Read the sender, destination, and exact proposed content. Granting read access to a Hereforth brief gives the requester the reviewed revision. Approving a standup opens a thread with the update you wrote. Approving an ordinary IT request records your decision. An external service still owns any actual IT change.
- **Send a brief to Ryan.** Pick the brief, choose Ryan from your paired teammates, and choose a session he has published. Review the text and destination before confirming. Ryan receives the offer in his Inbox and decides whether it reaches his session. His private chat stays on his machine. [Pair with a teammate](session-context.md#pair-teammates)

## Start a Codex or Claude task

Write the task on your phone and choose the client. To start work while you’re away, copy the prompt, open the provider’s Remote interface, choose the connected Mac or workspace, and start a new session there. You can also leave the prompt in Hereforth for review when you return to the Mac. A saved prompt and a running provider session have separate statuses.

Set up Remote in the provider app before leaving the Mac. ChatGPT’s Remote view supports starting tasks and reviewing permission requests on a connected computer. Claude Code Remote Control connects to a local environment you have enabled. Available tools, including computer use, depend on the client and its configuration. The provider presents its own permission prompts. [ChatGPT Remote](https://developers.openai.com/training/walkthroughs/working-on-your-phone) · [Claude Code Remote Control](https://code.claude.com/docs/en/remote-control)

## Drive the desktop yourself

On the Mac, open **System Settings → General → Sharing → Screen Sharing**. Select **Only these users** and add the Mac account you use to sign in. In your tailnet policy, allow the owner’s phone to reach the Mac for screen sharing (TCP 5900). Screen Sharing also listens on the Mac's reachable local interfaces. Use the Mac’s access controls and your network policy accordingly. The Hereforth HTTPS port serves the phone page independently. [Apple Screen Sharing](https://support.apple.com/guide/mac-help/turn-screen-sharing-on-or-off-mh11848/mac) · [Tailscale grants](https://tailscale.com/docs/features/access-control/grants)

On iPhone or iPad, save a screen in **Screens** for the Mac’s full tailnet hostname and use Mac user authentication in the viewer. Under **Open Desktop**, tap **Open in Screens** to launch that saved connection. Other compatible VNC viewers can use the same hostname. On another Mac, you can enter the hostname in Apple’s built-in Screen Sharing app. You sign in through the viewer, and you can turn Screen Sharing off on the Mac at any time. [Screens connection options](https://help.edovia.com/en/screens-5/getting-started/connecting) · [Screens URL support](https://help.edovia.com/en/screens-5/features/url-schemes)
