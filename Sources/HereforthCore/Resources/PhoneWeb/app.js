"use strict";

const byID = id => document.getElementById(id);
const form = id => byID(id);
const current = { view: "activity", authenticated: false, generation: 0 };
const taskForm = form("task-form");
const handoffForm = form("handoff-form");
let queueAttempt;
let handoffAttempt;
let usingPasskey = false;

function node(tag, content, className) {
  const element = document.createElement(tag);
  if (content !== undefined) element.textContent = content;
  if (className) element.className = className;
  return element;
}

function notice(message, error = false) {
  const target = byID("notice");
  target.textContent = message;
  target.hidden = !message;
  target.toggleAttribute("data-error", error);
}

async function request(path, payload) {
  const options = { credentials: "same-origin", cache: "no-store" };
  if (payload !== undefined) {
    options.method = "POST";
    options.headers = { "Content-Type": "application/json" };
    options.body = JSON.stringify(payload);
  }
  let response;
  try {
    response = await fetch(path, options);
  } catch {
    throw Error("Couldn’t reach Hereforth. Check that the Mac and its listener are online.");
  }
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    if (response.status === 401 && current.authenticated) {
      setAuthenticated(false);
      throw Error("Your session ended. Sign in again.");
    }
    const message = typeof data.error === "string" ? data.error : data.message;
    throw Error(typeof message === "string" ? message : "Hereforth couldn’t complete that request.");
  }
  return data;
}

const action = (name, payload = {}) => request("/api/actions/" + name, payload);

async function attempt(control, work) {
  if (control?.disabled) return;
  if (control) control.disabled = true;
  notice("");
  try {
    await work();
  } catch (error) {
    const cancelled = error.name === "NotAllowedError" || error.name === "AbortError";
    notice(cancelled ? "Passkey verification was cancelled or timed out." : error.message, true);
  } finally {
    if (control) control.disabled = false;
  }
}

function decode(value) {
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(atob(base64), char => char.charCodeAt(0));
}

function encode(buffer) {
  const binary = Array.from(new Uint8Array(buffer), byte => String.fromCharCode(byte)).join("");
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function publicKeyOptions(options) {
  const key = { ...(options.publicKey ?? options) };
  key.challenge = decode(key.challenge);
  if (key.user) key.user = { ...key.user, id: decode(key.user.id) };
  for (const list of ["allowCredentials", "excludeCredentials"]) {
    if (key[list]) key[list] = key[list].map(item => ({ ...item, id: decode(item.id) }));
  }
  return key;
}

function credentialJSON(credential) {
  if (typeof credential.toJSON === "function") return credential.toJSON();
  const response = credential.response;
  const fields = {};
  for (const field of ["clientDataJSON", "attestationObject", "authenticatorData", "signature", "userHandle"]) {
    if (field in response) fields[field] = response[field] === null ? null : encode(response[field]);
  }
  if (typeof response.getTransports === "function") fields.transports = response.getTransports();
  return {
    id: credential.id, rawId: encode(credential.rawId), type: credential.type,
    authenticatorAttachment: credential.authenticatorAttachment,
    response: fields, clientExtensionResults: credential.getClientExtensionResults()
  };
}

async function passkey(kind, payload) {
  if (!window.isSecureContext || !window.PublicKeyCredential) {
    throw Error("Open your private HTTPS Hereforth page in a browser that supports passkeys.");
  }
  if (usingPasskey) throw Error("Finish the current passkey prompt first.");
  usingPasskey = true;
  const prefix = "/api/auth/" + kind;
  try {
    const start = await request(prefix + "/start", payload);
    const method = kind === "register" ? "create" : "get";
    const credential = await navigator.credentials[method]({ publicKey: publicKeyOptions(start.options) });
    if (!credential) throw Error("Passkey verification was cancelled.");
    return await request(prefix + "/finish", { challengeId: start.challengeId, credential: credentialJSON(credential) });
  } finally {
    usingPasskey = false;
  }
}

const approve = (name, payload) => passkey("approve", { action: name, payload });

function setAuthenticated(authenticated) {
  current.authenticated = authenticated;
  current.generation += 1;
  byID("sign-in").hidden = authenticated;
  byID("sign-out").hidden = !authenticated;
  byID("owner").hidden = !authenticated;
  if (!authenticated) {
    for (const id of ["sessions", "tasks", "inbox-items", "handoff-review"]) byID(id).replaceChildren();
    for (const select of handoffForm.querySelectorAll("select")) select.replaceChildren();
    taskForm.reset();
    showRemote();
    form("pair-form").reset();
    queueAttempt = undefined;
    handoffAttempt = undefined;
  }
}

async function start() {
  const session = await request("/api/session");
  setAuthenticated(session.authenticated);
  if (session.authenticated) await selectView("activity");
  else byID("pairing").open = !session.passkey;
}

async function selectView(view) {
  current.view = view;
  const generation = ++current.generation;
  for (const pane of document.querySelectorAll(".page")) pane.hidden = pane.id !== view;
  for (const tab of document.querySelectorAll("[data-view]")) {
    if (tab.dataset.view === view) tab.setAttribute("aria-current", "page");
    else tab.removeAttribute("aria-current");
  }
  const visible = () => current.authenticated && current.generation === generation;
  if (view === "activity") await loadActivity(visible);
  if (view === "inbox") await loadInbox(visible);
  if (view === "handoff") await loadHandoffChoices(visible);
}

function card(title, details, body) {
  const panel = node("article", undefined, "panel");
  panel.append(node("h3", title));
  if (details) panel.append(node("p", details, "muted"));
  if (body) panel.append(node("p", body, "exact"));
  return panel;
}

function empty(text) { return node("p", text, "empty"); }
function date(value) {
  const timestamp = new Date(value);
  return value && !Number.isNaN(timestamp.valueOf()) ? timestamp.toLocaleString() : "";
}
function clientName(value) {
  return ({ codex: "Codex", claude: "Claude Code", "claude-code": "Claude Code" })[value] ?? value;
}
function taskState(value) {
  return ({ pending_review: "Needs Mac review", approved: "Prompt approved", declined: "Declined" })[value] ?? value;
}
const joined = (...values) => values.filter(Boolean).join(" · ");

async function loadActivity(visible = () => current.authenticated && current.view === "activity") {
  const response = await action("activity");
  if (!visible()) return;
  const sessions = response.sessions.map(session => {
    const detail = joined(clientName(session.client), session.state, date(session.activityAt || session.lastSeenAt));
    const panel = card(session.label, detail, session.summary);
    if (session.phase || session.summary) panel.append(node("p", joined("Session-reported", session.phase), "muted"));
    return panel;
  });
  const tasks = response.tasks.map(task => {
    const panel = card(
      clientName(task.client),
      joined(task.kind === "computer" ? "Computer use" : "Text task", taskState(task.state), date(task.updatedAt)),
      (task.description ?? "") + (task.descriptionTruncated ? "…" : "")
    );
    const details = node("div");
    panel.append(button("Review Prompt", async () => {
      const saved = await action("get_task", { id: task.id });
      if (!visible() || !panel.isConnected) return;
      const exact = node("p", saved.prompt, "exact");
      details.replaceChildren(node("h3", "Exact prompt"), exact);
      const assistant = remote[saved.client];
      if (assistant && saved.state !== "declined") {
        const open = node("a", assistant.button, "button");
        open.href = assistant.url;
        open.rel = "noreferrer";
        details.append(node("p", assistant.steps, "muted"),
                       group(button("Copy Task", () => copy(saved.prompt)), open));
      }
      details.className = "preview";
    }), details);
    return panel;
  });
  byID("sessions").replaceChildren(...(sessions.length ? sessions : [empty("No published sessions.")]));
  byID("tasks").replaceChildren(...(tasks.length ? tasks : [empty("No task requests.")]));
}

function button(title, work, primary = false) {
  const control = node("button", title, primary ? "primary" : undefined);
  control.type = "button";
  control.addEventListener("click", () => attempt(control, work));
  return control;
}

function group(...controls) {
  const row = node("div", undefined, "actions");
  row.append(...controls);
  return row;
}

function fill(select, items, placeholder) {
  const prompt = node("option", placeholder);
  prompt.value = "";
  select.replaceChildren(prompt, ...items.map(({ id, title }) => {
    const option = node("option", title);
    option.value = id;
    return option;
  }));
}

function notifySaved(response) {
  notice(({ approved: "Approved", declined: "Declined", fulfilled: "Fulfilled",
            allowed: "Allowed for the addressed session", reviewed: "Reviewed" })[response.state] ?? "Decision recorded.");
}

async function loadInbox(visible = () => current.authenticated && current.view === "inbox") {
  const { items } = await action("inbox");
  if (!visible()) return;
  byID("inbox-items").replaceChildren(...(items.length ? items.map(inboxCard) : [empty("Nothing waiting for review.")]));
}

function inboxCard(item) {
  const panel = card(item.label, "From " + item.sender, item.body);
  if (item.scope) panel.append(node("p", item.scope, "muted"));
  const decide = async (name, values) => {
    const result = await approve(name, { id: item.id, ...values });
    await loadInbox();
    notifySaved(result);
  };
  const decision = approve => ({ digest: item.digest, approve });
  if (item.kind === "context") {
    panel.append(group(
      button("Decline", () => decide("review_context", decision(false))),
      button("Add to Session", () => decide("review_context", decision(true)), true)
    ));
  } else {
    const decline = button("Decline", () => decide("review_work", decision(false)));
    const preview = node("div");
    if (item.requestsBrief) {
      panel.append(group(decline, button("Choose Draft", async () => {
        const { briefs } = await action("list_briefs");
        preview.replaceChildren();
        const candidates = item.briefID ? briefs.filter(brief => brief.id === item.briefID) : briefs;
        if (!candidates.length) {
          preview.append(empty("The requested draft is unavailable on your Mac."));
          return;
        }
        const pick = node("label", "Draft to share");
        const select = node("select");
        fill(select, candidates.map(brief => ({ id: brief.id, title: brief.title })), "Choose a draft");
        if (item.briefID) select.value = item.briefID;
        pick.append(select);
        const details = node("div");
        preview.append(pick, button("Preview Draft", async () => {
          details.replaceChildren();
          if (!select.value) throw Error("Choose a draft first.");
          const selected = select.value;
          const draft = await action("preview_work", { id: item.id, brief_id: selected });
          if (select.value !== selected) return;
          const review = card(draft.title, joined("For " + draft.sender, draft.scope), draft.markdown);
          review.append(button("Grant Read Access", () => decide("review_work", {
            ...decision(true), brief_id: draft.briefID, revision_digest: draft.digest
          }), true));
          details.replaceChildren(review);
        }), details);
        select.addEventListener("change", () => details.replaceChildren());
      })), preview);
    } else if (item.requestsStandup) {
      const label = node("label", "Opening update");
      const editor = node("textarea");
      editor.rows = 4;
      editor.maxLength = 12000;
      label.append(editor);
      editor.addEventListener("input", () => preview.replaceChildren());
      panel.append(label, group(decline, button("Review Update", async () => {
        preview.replaceChildren();
        const text = editor.value;
        if (!text.trim()) throw Error("Write the opening update first.");
        const opening = await action("preview_standup", { id: item.id, approved_text: text });
        if (editor.value !== text) return;
        const review = card("Exact opening update", joined("For " + opening.sender, opening.scope), opening.approvedText);
        review.append(button("Approve & Open Thread", () => decide("review_standup", {
          digest: opening.digest, approved_text: opening.approvedText
        }), true));
        preview.replaceChildren(review);
      }, true)), preview);
    } else {
      panel.append(group(decline, button("Mark Reviewed", () => decide("review_work", decision(true)), true)));
    }
  }
  return panel;
}

async function loadHandoffChoices(visible) {
  const [briefs, peers] = await Promise.all([action("list_briefs"), action("list_peers")]);
  if (!visible()) return;
  fill(handoffForm.elements.brief, briefs.briefs.map(item => ({ id: item.id, title: joined(item.title, item.recipient) })),
       briefs.briefs.length ? "Choose a brief" : "No local briefs");
  fill(handoffForm.elements.peer, peers.peers.map(item => ({ id: item.name, title: item.name })),
       peers.peers.length ? "Choose a teammate" : "No paired teammates");
  fill(handoffForm.elements.session, [], "Choose a teammate first");
  byID("handoff-review").replaceChildren();
  byID("new-preview").hidden = true;
}

function handoffValues() {
  return {
    brief_id: handoffForm.elements.brief.value,
    peer: handoffForm.elements.peer.value,
    session_id: handoffForm.elements.session.value
  };
}

async function loadPeerSessions() {
  const peer = handoffForm.elements.peer.value;
  const select = handoffForm.elements.session;
  fill(select, [], peer ? "Loading sessions…" : "Choose a teammate first");
  if (!peer) return;
  const { sessions } = await action("list_peer_sessions", { peer });
  if (!current.authenticated || peer !== handoffForm.elements.peer.value) return;
  fill(select, sessions.map(item => ({ id: item.id, title: item.label })),
       sessions.length ? "Choose a session" : "No published sessions");
}

const remote = {
  codex: {
    title: "Continue in ChatGPT Remote", button: "Open ChatGPT",
    url: "https://chatgpt.com/",
    help: "https://developers.openai.com/training/walkthroughs/working-on-your-phone",
    steps: "Open Remote in ChatGPT, choose your linked Mac, create a new Codex task, then paste the prompt."
  },
  claude: {
    title: "Continue in Claude Code Remote Control", button: "Open Claude Code",
    url: "https://claude.ai/code",
    help: "https://code.claude.com/docs/en/remote-control",
    steps: "Open Code in Claude, choose your linked Mac’s Remote Control server, start a new session, then paste the prompt."
  }
};

function showRemote() {
  const item = remote[taskForm.elements.client.value];
  byID("remote-title").textContent = item.title;
  byID("remote-steps").textContent = item.steps;
  byID("open-remote").textContent = item.button;
  byID("open-remote").href = item.url;
  byID("remote-help").href = item.help;
}

async function copy(value) {
  if (!value.trim()) throw Error("Enter the exact prompt first.");
  try { await navigator.clipboard.writeText(value); }
  catch { throw Error("Couldn’t copy. Select the text and use your phone’s Copy command."); }
  notice("Copied to the clipboard.");
}

function setupDesktop() {
  const hostname = window.location.hostname;
  byID("desktop").hidden = !/^[a-z0-9.-]+$/i.test(hostname);
  byID("desktop-host").textContent = hostname;
  byID("open-desktop").href = "screens://" + hostname;
  const control = byID("copy-host");
  control.addEventListener("click", () => attempt(control, () => copy(hostname)));
}

function submit(target, work) {
  target.addEventListener("submit", event => {
    event.preventDefault();
    attempt(event.submitter, work);
  });
}

for (const tab of document.querySelectorAll("[data-view]")) {
  tab.addEventListener("click", () => attempt(tab, () => selectView(tab.dataset.view)));
}

byID("login").addEventListener("click", () => attempt(byID("login"), async () => {
  await passkey("login", {});
  setAuthenticated(true);
  await selectView("activity");
}));
submit(form("pair-form"), async () => {
  const pair = form("pair-form");
  const code = pair.elements.code.value.trim();
  pair.reset();
  await passkey("register", { code });
  setAuthenticated(true);
  await selectView("activity");
});
byID("sign-out").addEventListener("click", () => attempt(byID("sign-out"), async () => {
  await request("/api/auth/logout", {});
  setAuthenticated(false);
}));
byID("refresh").addEventListener("click", () => attempt(byID("refresh"), () => loadActivity()));
byID("refresh-inbox").addEventListener("click", () => attempt(byID("refresh-inbox"), () => loadInbox()));

taskForm.elements.client.addEventListener("change", showRemote);
byID("copy-task").addEventListener("click", () => attempt(byID("copy-task"), () => copy(taskForm.elements.prompt.value)));
submit(taskForm, async () => {
  const values = Object.fromEntries(new FormData(taskForm));
  if (!values.prompt.trim()) throw Error("Enter the exact prompt first.");
  const key = JSON.stringify(values);
  if (!queueAttempt || queueAttempt.key !== key) queueAttempt = { key, id: crypto.randomUUID() };
  const result = await approve("queue_task", { ...values, request_id: queueAttempt.id });
  if (result.state === "pending_review") notice("Queued for review on your Mac. You can also continue in your assistant.");
  else notifySaved(result);
});

handoffForm.addEventListener("change", event => {
  handoffAttempt = undefined;
  byID("handoff-review").replaceChildren();
  byID("new-preview").hidden = true;
  if (event.target === handoffForm.elements.peer) attempt(null, loadPeerSessions);
});
byID("new-preview").addEventListener("click", () => {
  handoffAttempt = undefined;
  byID("handoff-review").replaceChildren();
  handoffForm.requestSubmit();
});
submit(handoffForm, async () => {
  const values = handoffValues();
  const key = JSON.stringify(values);
  if (!handoffAttempt || handoffAttempt.key !== key) handoffAttempt = { key, id: crypto.randomUUID() };
  const preview = await action("preview_handoff", { ...values, request_id: handoffAttempt.id }).catch(error => {
    byID("new-preview").hidden = false;
    throw error;
  });
  if (!current.authenticated || current.view !== "handoff" || JSON.stringify(handoffValues()) !== key) return;
  byID("new-preview").hidden = true;
  const review = card(preview.title, joined(preview.peer, preview.sessionLabel), preview.markdown);
  const confirm = button("Send for Teammate Review", async () => {
    const outcome = await approve("send_handoff", { id: preview.id, digest: preview.digest }).catch(error => {
      byID("new-preview").hidden = false;
      throw error;
    });
    byID("new-preview").hidden = true;
    review.replaceChildren(node("h3", "Handoff submitted"),
                           node("p", joined(outcome.peer, outcome.sessionLabel), "muted"));
    if (typeof outcome.receipt === "string" && outcome.receipt) review.append(node("p", outcome.receipt, "exact"));
  }, true);
  review.append(confirm);
  byID("handoff-review").replaceChildren(review);
});

setupDesktop();
showRemote();
attempt(null, start);
