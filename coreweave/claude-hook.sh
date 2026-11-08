#!/usr/bin/env bash
# Claude Code hook: tells agents on the pod when pod-guard pauses or resumes
# work, from pod-guard's status file. pod-guard installs it for every session
# in ~/.claude/settings.json.
#
#   claude-hook.sh <event>   SessionStart, UserPromptSubmit, PostToolUse:
#                            add the status to the model's context, once per
#                            event per session. PostToolUseFailure: always, since
#                            a command frozen by the pause is a likely cause.
#   claude-hook.sh watch     async PreToolUse(Bash) hook with asyncRewake: waits
#                            in the background and wakes the agent if a pause
#                            starts while its command (or a background task) is
#                            running, since no hook fires until a frozen command
#                            ends. One watcher per session, kept alive while the
#                            session keeps running Bash.
#
# Hook input JSON arrives on stdin; session_id and (inside a subagent) agent_id are used.
# Subagents share their parent's session_id, so state is kept per agent: otherwise the first
# agent to fire a hook claims the event and every other agent in the session never sees it.

status=${POD_GUARD_STATUS:-/run/pod-guard/status}
watch_idle=${POD_GUARD_WATCH_IDLE:-3600} # seconds without Bash calls before a watcher exits
poll=${POD_GUARD_WATCH_POLL:-2}

input=$(cat)
field() { sed -n "s/.*\"$1\" *: *\"\([^\"]*\)\".*/\1/p" <<<"$input" | head -n1; }
session=$(field session_id)
agent=$(field agent_id)
state="${status%/*}/sessions/${session:-unknown}${agent:+/agents/$agent}"
mkdir -p "$state" 2>/dev/null || exit 0

key() { head -n1 "$status" 2>/dev/null; }
message() { tail -n +2 "$status"; }

# Claim the current event for this session; fails if already shown.
claim() {
    local k
    k=$(key)
    [[ -n $k && $k != "$(cat "$state/seen" 2>/dev/null)" ]] || return 1
    echo "$k" >"$state/seen"
}

case $1 in
    watch)
        touch "$state/heartbeat"
        # Another watcher for this session is alive: the heartbeat extends it.
        if [[ -f $state/watcher ]] && kill -0 "$(<"$state/watcher")" 2>/dev/null; then
            exit 0
        fi
        echo $$ >"$state/watcher"
        while (($(date +%s) - $(stat -c %Y "$state/heartbeat") < watch_idle)); do
            # Only a new pause is urgent enough to wake the agent.
            if [[ $(key) == paused* ]] && claim; then
                message >&2
                exit 2
            fi
            sleep "$poll"
        done
        ;;
    PostToolUseFailure)
        [[ -s $status ]] || exit 0
        claim
        message >&2
        exit 2
        ;;
    *)
        claim || exit 0
        python3 -c 'import json, sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": sys.argv[1], "additionalContext": sys.argv[2]}}))' "$1" "$(message)"
        ;;
esac
