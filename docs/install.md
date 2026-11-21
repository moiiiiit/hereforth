# Install Hereforth

The disk image requires an Apple Silicon Mac running macOS 14 or later. It contains a signed, notarized app that runs without Xcode or Command Line Tools.

1. [Download Hereforth.dmg](https://github.com/moiiiiit/hereforth/releases/latest/download/Hereforth.dmg) and open the disk image.
2. Drag Hereforth to **Applications**. You can put it in the **Applications** folder in your home folder if you prefer a per-user installation.
3. Eject the disk image and open Hereforth from the folder where you installed it.
4. In the **Hereforth** menu, select **Connect Assistants…** and choose your client. Claude Desktop, Claude Code, Codex, and Kimi Code have a **Connect** button. For OpenCode, LM Studio, or another local client, use the copy controls and the setup steps below. Open Claude Desktop once before connecting it. Claude Code and Codex use their existing CLI. If Hereforth asks for the executable, choose it in the file picker.

Fully quit and reopen Claude Desktop after connecting it, or start a fresh Claude Code or Codex session. If your client already has a conflicting server called `hereforth`, Hereforth preserves its settings so you can review that entry in the client. Managed Macs follow their organization's installation and connector rules.

Choose **Hereforth → Check for Updates…** for an immediate check. Automatic checks and installation can be managed in **Hereforth → Settings**. Your library and connector settings stay separate from the app bundle during an update.

## Connect another assistant

Hereforth runs as a local stdio MCP server. The client starts the helper on the Mac with the library. Use a model that can call the client’s tools.

### Kimi Code

In **Connect Assistants…**, select **Kimi Code** and click **Connect Kimi Code**. Hereforth adds a `hereforth` entry to the user-level `~/.kimi-code/mcp.json` (or `$KIMI_CODE_HOME/mcp.json` if set for the connecting process). Open a new Kimi Code session and run `/mcp` to check the connection. Use the current Kimi Code CLI. [Kimi Code MCP documentation](https://moonshotai.github.io/kimi-code/en/customization/mcp.html)

### OpenCode

Select **OpenCode** in **Connect Assistants…**, click **Copy Command**, and run it in Terminal from the project where you use OpenCode. The OpenCode CLI writes the configuration for its installed version. For a standard Applications install, run the following command.

```sh
opencode mcp add hereforth -- '/Applications/Hereforth.app/Contents/MacOS/hereforth' mcp
```

Run `opencode mcp list` to check the entry, then open a new OpenCode session. [OpenCode MCP documentation](https://opencode.ai/docs/mcp-servers/)

### LM Studio

Select **LM Studio** in **Connect Assistants…** and click **Copy JSON Configuration**. In LM Studio’s **Program** sidebar, select **Install → Edit mcp.json**. Add the copied `hereforth` entry to `mcpServers` and save.

```json
{
  "mcpServers": {
    "hereforth": {
      "command": "/Applications/Hereforth.app/Contents/MacOS/hereforth",
      "args": ["mcp"]
    }
  }
}
```

Choose a tool-capable model in LM Studio, then check that Hereforth is available in the **Program** sidebar. [LM Studio MCP documentation](https://lmstudio.ai/docs/app/mcp)

### Other local MCP clients

Select **Other Local MCP Client** in **Connect Assistants…** to see the absolute executable path and the single argument `mcp`. Choose the local or stdio transport in your client and enter those values. If the client accepts one shell command, use **Copy Command**. Name the server `hereforth`.

For a first check, ask your assistant “Which conversations have I imported? Use Hereforth.” A client using a hosted model may send returned passages to that provider. Use a local model if you want those passages to stay on your Mac.

## Build from signed source

Building from signed source requires Apple’s Swift 6.3 or later toolchain. Check with `swift --version`. If those tools are missing, run `xcode-select --install` and complete the Mac's installation prompt.

```sh
curl --fail --show-error --location --proto '=https' --proto-redir '=https' \
  https://github.com/moiiiiit/hereforth/releases/latest/download/install.sh \
  -o hereforth-bootstrap.sh
bash hereforth-bootstrap.sh
```

Pass one or more of `--claude-code`, `--claude-desktop`, and `--codex` to connect those clients during installation. The source installer builds into `~/Applications`, verifies the highest stable annotated Git tag against the pinned Hereforth release key, and stops if that tag fails verification. The local source build uses ad hoc code signing.

### Inspect the verified source first

Open the downloaded bootstrap in a text editor before running it, or clone the release source for inspection.

```sh
git clone --no-checkout https://github.com/moiiiiit/hereforth.git hereforth-source
cd hereforth-source
curl --fail --show-error --proto '=https' \
  https://raw.githubusercontent.com/moiiiiit/hereforth/main/scripts/release-signers \
  -o ../hereforth-release-signers
awk '{print $3, $4}' ../hereforth-release-signers | ssh-keygen -lf /dev/stdin
```

Check the Ed25519 fingerprint against the release key you trust. The current fingerprint is `SHA256:FxzNc1UgF8y6U2RT8Ccm9DhNWCVYB+w931RJHvxskmw`. Replace `vX.Y.Z` below with a stable tag from [Hereforth releases](https://github.com/moiiiiit/hereforth/releases).

```sh
tag=vX.Y.Z
git -c gpg.format=ssh \
  -c gpg.ssh.allowedSignersFile="$(cd .. && pwd)/hereforth-release-signers" \
  verify-tag "$tag"
git cat-file -p "$tag" | sed -n '1,3p'
```

Continue after verification succeeds and the tag header reports `type commit` and the exact `tag` you chose.

```sh
git switch --detach "$tag"
less scripts/install.sh
./scripts/install.sh
```

### Updates for a source build

Stable source installations check daily at 10 a.m. local time and install a newer verified source release when available. Use the bundled helper for manual checks and to change the schedule.

```sh
helper="$HOME/Applications/Hereforth.app/Contents/MacOS/hereforth"
"$helper" update status
"$helper" update check
"$helper" update install
```

Use `"$helper" update disable` to turn off scheduled updates or `"$helper" update enable` to restore them. Manual checks and installation remain available when the schedule is off.
