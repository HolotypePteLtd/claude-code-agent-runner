#!/bin/bash
# cleanup-git-config.sh — Runs before every job via ACTIONS_RUNNER_HOOK_JOB_STARTED
#
# Removes any insteadOf rules that rewrite HTTPS→SSH, which tools like
# Claude Code may add during a job. These break actions/checkout.

git config --global --unset-all url."git@github.com:".insteadOf 2>/dev/null || true
git config --global --unset-all url."ssh://git@github.com/".insteadOf 2>/dev/null || true

# Re-ensure the correct direction: SSH→HTTPS
git config --global url."https://github.com/".insteadOf "git@github.com:"
