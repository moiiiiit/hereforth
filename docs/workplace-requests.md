# Workplace requests in Hereforth

An employee should be able to open their usual assistant and type “The support rotation starts Monday. Can I see the incident dashboard for that week?” They may know neither the ticket type nor the name of the team that owns it. Start with what they need. Ask for the one missing detail that changes the route, the scope of access, or the decision. Keep the rest of the conversation intact when another person takes over.

## Four requests the same interaction should support

| What someone asks | What the receiving session needs | What would count as completion |
| --- | --- | --- |
| “My replacement Mac won’t enroll. Can IT help before Monday?” | Device asset reference, the failed step, and a way to reach the requester. A help desk can request a redacted error message if needed. | The help desk records a resolution, and the requester confirms enrollment works. |
| “Can Security review sending pseudonymous usage events to this service?” | The proposed data flow, data classes, retention, and design link. The security reviewer can ask for a change or record conditions. | A review decision tied to that design revision. Material changes reopen the review. |
| “Give me read-only staging analytics for seven days for incident 428.” | Requester, specific resource, role, purpose, expiry, and incident reference. A data owner can review a scoped request through the identity system. | The identity system reports the actual grant and its expiry. A chat acknowledgment alone leaves fulfillment open. |
| “Can we use Acme Forms for the pilot?” | Intended use and data, estimated cost, and budget owner. Security, procurement, and legal can each review the part relevant to them. | The procurement record shows the applicable decisions and any restrictions. A purchase or signature is a separate authorized action. |

## Working queue

Both people install Hereforth and [pair their Macs](session-context.md). Leave Ryan’s peer service running. A personal work request can arrive while Ryan has no assistant session open. After receipt, his Mac keeps it for review after a restart. The sending assistant chooses a category from the request wording. An unusual request can go to **Other**.

1. Mohit asks Claude or Codex, **“Ask Ryan for seven days of read-only access to the Juniper release decision brief in Hereforth.”** His assistant submits the request, preserves the returned identifiers, and can ask for its status later.
2. At his desk, Ryan opens **Work Requests**, filters **Data access**, and reviews the sender and justification. For an explicit Hereforth brief request, he selects the intended brief, inspects its exact text and version, and sees the recipient, read-only scope, and duration before granting access. He can also decline.
3. On approval Hereforth grants access to that version and records fulfillment in the same local transaction. Mohit asks **“Read the brief Ryan approved.”** His assistant retrieves the approved Markdown through his paired identity. Ryan can revoke future reads. A copy already returned to Mohit can remain in his assistant history.

An IT, security, vendor, or external dataset request can go through the same queue. Human review is recorded for these cases. Fulfillment needs an adapter for the system that owns the requested action. A category label alone never authorizes an effect. The person creating a request has no separate issue to file, and the person granting an implemented capability has no ticket to close.

## Interaction design

1. **Describe the need.** Accept free text. A request for something new can still reach a teammate. Example prompts are invitations to try the feature rather than a required menu of categories.
2. **Find the destination.** Address work to a configured person for later review. Address context to a published session when someone is already working on the topic. A future team directory could resolve “who owns staging analytics?” to a responsible group, a delegate, or a service queue. When the owner is ambiguous, show the plausible destinations and ask.
3. **Review the exchange.** Show the sender which session will receive the text. The recipient sees the sender, target, and exact wording in Hereforth. **Add to Session** permits their assistant to read that material. It gives the sender no authority to run tools, grant access, or spend money.
4. **Track the actual decision.** Delivery has its own receipt. For each supported effect, record the authenticated requester, approved object and version, scope, and outcome. An external adapter can use a scoped API directly, check whether the requested effect occurred, and reconcile retries. If a service already has a mandatory approval workflow, link its record and honor its approvers. The employee should be able to ask “Is it in Ryan’s session?”, “Who still needs to approve?”, and “Do I have access yet?” and get independently supported answers.

## First corporate pilot

Choose one low-risk, time-limited access request that already has a named owner. Start with a reference to a synthetic incident and the smallest relevant excerpt. Exercise a request for clarification, a refusal, and a successful decision. Give the requester status about their own case and keep another employee’s case out of the answer. Record who acted, for what scope, and when. For broad deployment, add organizational identity, offboarding, retention, and a recovery path when the target session ends.

The first executable action is a seven-day read grant for a frozen Hereforth brief. External IAM, devices, security exceptions, vendor onboarding, spending, and contracts need independent connectors and appropriate authority. Jira Service Management documents workflows with human approval steps. Okta Access Requests defines eligible requesters, approvers, resources, and access duration. Those are candidate sources for authoritative decisions when integrations arrive. [Jira approval workflows](https://support.atlassian.com/jira-service-management-cloud/docs/set-up-approvals/) · [Okta Access Requests](https://help.okta.com/oie/en-us/Content/Topics/identity-governance/access-requests/ar-overview.htm)
