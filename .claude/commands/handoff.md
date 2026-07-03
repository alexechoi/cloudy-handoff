---
description: Hand off the current task to a Cloud Run job that runs until done
argument-hint: <task description>
allowed-tools: Bash(cloudy-handoff:*)
---
Offload the following task to a Cloud Run job (it runs autonomously until done,
then pushes a `handoff/<id>` branch and opens a PR):

!`cloudy-handoff "$ARGUMENTS"`
