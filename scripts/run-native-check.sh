#!/bin/bash
set -euo pipefail
# Capture the original failing stack. A trap and a nonzero native exit both fail CI.
exec xcrun lldb --no-lldbinit --batch \
    -o run \
    -k 'thread backtrace all' \
    -k 'process kill' \
    -k 'script import os; os._exit(1)' \
    -o 'script import os; p=lldb.debugger.GetSelectedTarget().GetProcess(); os._exit(p.GetExitStatus() if p.GetState()==lldb.eStateExited else 1)' \
    -- "$@"
