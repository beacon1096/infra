{ lib, runCommand, python3, pi-coding-agent }:

let
  # `logcap` writes a 64 MiB log to prove the cap holds; it is the one case not
  # worth its runtime on every push. Everything else runs.
  cases = [
    "success"
    "failure"
    "timeout"
    "cancel"
    "yield"
    "foreground"
    "multiple"
    "backlog"
    "observed"
    "tree"
    "status"
    "truncate"
    "rpc"
    "abort"
  ];
in
runCommand "pi-exec-smoke"
{
  nativeBuildInputs = [ python3 pi-coding-agent ];
  PI_EXEC_EXTENSION = ../extension.ts;
} ''
  export HOME="$TMPDIR/home"
  mkdir -p "$HOME"
  ${lib.concatMapStringsSep "\n" (case: ''
    echo "== pi-exec smoke: ${case}"
    python3 ${./smoke.py} ${case}
  '') cases}
  touch "$out"
''
