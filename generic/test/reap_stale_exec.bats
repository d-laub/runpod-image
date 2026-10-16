#!/usr/bin/env bats

# reap-stale-exec.sh runs from .bashrc on each new `kubectl exec -- bash` login
# and kills the shells (and their zellij clients) left behind by earlier exec
# sessions whose client side disconnected. Kubelet never closes those ptys, so
# nothing else ever cleans them up. Fed a fake process table via _REAP_PS.

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/reap-stale-exec.sh"

setup() {
    TMPD="$(mktemp -d)"
    # pid ppid args — PID 1 and the current shell (500) are also ppid 0.
    cat > "$TMPD/ps" <<'PS'
      1       0 /bin/bash /start.sh
    100       1 /root/.pixi/envs/zellij/bin/zellij --server /tmp/zellij-0/contract_version_1/work
    101     100 /bin/bash
    200       0 bash
    201     200 /root/.pixi/envs/zellij/bin/zellij a work
    300       0 bash
    400       0 bash
    401     400 python train.py
    450       0 bash -c echo hi
    500       0 bash
    501     500 ps -eo pid=,ppid=,args=
PS
}

teardown() {
    rm -rf "$TMPD"
}

_run() {
    run env _REAP_PS="cat $TMPD/ps" bash "$SCRIPT" --dry-run 500
}

@test "kills the zellij client of a stale exec shell, then hangs up the shell" {
    _run
    [[ $output == *"kill -KILL 201"* ]]
    [[ $output == *"kill -HUP 200"* ]]
}

@test "hangs up a stale exec shell with no children" {
    _run
    [[ $output == *"kill -HUP 300"* ]]
}

@test "leaves a stale exec shell alone when it runs something other than zellij" {
    _run
    [[ $output != *"kill -HUP 400"* && $output != *"kill -KILL 401"* ]]
    [[ $output == *"skipping exec shell 400"* ]]
}

@test "never touches the current shell, PID 1, non-interactive execs, or the zellij server" {
    _run
    for pid in 500 501 1 450 100 101; do
        [[ $output != *"kill -KILL $pid"* && $output != *"kill -HUP $pid"* ]]
    done
}

@test "reports how many shells it reaped" {
    _run
    [[ $output == *"reaped 2 stale exec shell(s)"* ]]
}

@test "is silent when there is nothing to reap" {
    printf '      1       0 /bin/bash /start.sh\n    500       0 bash\n' > "$TMPD/ps"
    _run
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
