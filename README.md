# Hereforth

Hereforth is a proposed personal assistant that runs on your Mac. You and your teammates ask questions in the assistants you already use. For example, a teammate can ask their own Claude, “What is Mohit working on right now?” and get his shared work, blockers, and last confirmed updates directly in that conversation. Hereforth keeps one local memory across ChatGPT, Claude, Cursor, and Granola.

Imagine asking, “What did we decide about the launch yesterday? Pick up the draft where I left off.” Hereforth should find the decision in your meeting notes, show you the source, and open a task with the draft and its earlier discussion. Later, you can ask how the work is going from your phone or let a teammate ask for the part you chose to share.

The project is in design and feasibility research. The intended release is open source. The first milestone is a Mac service that can answer a question using evidence from two conversations and serve an authorized teammate status query over the Model Context Protocol (MCP), with the Hereforth window closed.

Ask what your agents are working on, which task needs your input, or what finished while you were away. Every planned view has a conversational query, including usage and Mac availability. You can share a project's live status with selected teammates. [Agent activity on Home](docs/plan.md#what-my-agents-are-working-on)

One team goal is to retire routine status syncs. Ask Claude “Give me the team standup” for a short list grouped by person, with recent progress, current work, and requests for help. Follow up with “Who needs a review?” Hereforth will let owners choose when their Mac is available to answer and track the model usage behind those updates. [Team standup design](docs/plan.md#team-standup)

Read the [implementation plan](docs/plan.md), [integration research](docs/research.md), [teammate sharing design](docs/teammate-knowledge.md), and [Keep Awake and usage controls](docs/availability-and-usage.md).
