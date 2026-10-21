# Example cards: one "## Q:" section per question

Each card is kept whole as one passage and ranks above raw docs, so write the answer you would want read back to
you on a call. **Say** is the line to speak; the rest gives the model the substance behind it.

## Q: Should we keep one big state file or split it up?
**Say:** Split it. One state file per unit keeps plans fast and limits what one bad apply can break.
**Answer:** A single state file for an environment is the thing teams regret most: every plan reads everything,
every engineer queues on one lock, and one mistake can touch resources nobody meant to change. Break the
environment into units (a network, a database, a cluster), each with its own state, and let the orchestrator
order them by dependency.
**Our view:** Blast radius and plan time are the two reasons, and they are enough. Break it up before it hurts.
**Watch out:** Splitting an existing state means moving resources between states; do it one unit at a time with a
plan that shows no changes at the end of each step.
**Sources:** your docs, your support history, your own runbooks. (Free text; it is indexed with the card.)
**Tags:** state, blast radius, plan time, monolith

## Q: What do we say when they ask where the UI is?
**Say:** The UI is your git provider: pull requests, plans and applies are where your engineers already live.
**Answer:** There is no separate console to learn or secure. Every change is a pull request with the plan attached;
approval and apply happen there, with the audit trail git already keeps.
**Our view:** Say it before they ask. A second dashboard is a cost, not a feature.
**Watch out:** Some buyers want a status page for non-engineers; point at the pull request list and the drift
report rather than promising a dashboard.
**Sources:** positioning notes.
**Tags:** UI, dashboard, objection, git provider
