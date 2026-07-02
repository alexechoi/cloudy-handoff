---
description: Resume a previous cloud handoff with more instructions
argument-hint: <session-id> <additional instructions>
allowed-tools: Bash(cloudy-handoff:*)
---
Resume an existing handoff session. The cloud job checks out the same
`handoff/<id>` branch, restores the agent's transcript so it keeps full context,
runs the new instructions, and updates the same PR.

The first argument is the session id; the rest is the follow-up task.

!`cloudy-handoff --resume $ARGUMENTS`
