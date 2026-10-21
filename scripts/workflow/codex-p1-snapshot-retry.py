#!/usr/bin/env python3
"""Evaluate and publish one existing Codex P1 lease, retrying snapshot drift.

Exit 0 clear, 1 feedback blocked, 2 unreadable/config/head failure, 3 bounded
snapshot recovery exhausted. No lease creation or identity/credential changes.

Pending (#2618): when the caller names CODEX_P1_PENDING_VERDICT_FILE, the
driver removes that file first and writes exactly `pending` there only when
the verdict it published is rc 1, the gate wrote `pending` to its own private
verdict file on that same attempt (codex-p1-gate.sh's MERGEPATH_GATE_VERDICT_FILE
contract: the only blocker is a non-blocking finding awaiting disposition), and
the lease PATCH that closed the generation red succeeded. A drifted attempt's
file never counts, and every other outcome leaves the caller's file absent.
"""
import fcntl
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ATTEMPTS = 3
SECONDS = 180
API_COMMANDS = 200


def transport():
    """Budget every nested gh invocation; pagination shares the wall deadline."""
    with open(os.environ['SNAPSHOT_API_COUNTER'], 'r+') as counter:
        fcntl.flock(counter, fcntl.LOCK_EX)
        count = int(counter.read() or '0')
        if count >= API_COMMANDS:
            Path(os.environ['SNAPSHOT_EXHAUSTED']).touch()
            print('Feedback snapshot API-command budget exhausted (200).', file=sys.stderr)
            return 75
        counter.seek(0)
        counter.write(str(count + 1))
        counter.truncate()
    # The caller owns the process-group deadline, including all paginated reads.
    return subprocess.call([os.environ['SNAPSHOT_REAL_GH'], *sys.argv[1:]])


# codex-p1-gate.sh's die() text for a feedback-accounting failure. The check
# keeps its historical name, so the title must say which question failed: an
# undispositioned finding in the accounting inventory, whichever provider
# raised it, or a legacy Codex thread (#2536). The inventory's scope (the
# recognized providers and non-ignored tiers) is the accounting spec's, so the
# title does not restate it.
ACCOUNTING_FAILURE = 'review feedback is unaccounted'
PENDING_ENV = 'CODEX_P1_PENDING_VERDICT_FILE'
GATE_VERDICT_ENV = 'MERGEPATH_GATE_VERDICT_FILE'


def read_pending(path):
    """True only when the gate wrote exactly `pending` to its private file."""
    try:
        return path.read_text() in ('pending', 'pending\n')
    except OSError:
        return False


def verdict_title(gate_rc, gate_text):
    if gate_rc == 0:
        return 'Codex feedback gate (leased re-evaluation)'
    if ACCOUNTING_FAILURE in gate_text:
        return ('Review feedback unaccounted: '
                'run scripts/review-feedback-accounting.sh <PR#>')
    return 'Codex blocking-tier review threads unresolved on the current head'


class Unreadable(Exception):
    pass


class Exhausted(Exception):
    pass


def main():
    if len(sys.argv) != 6:
        print('usage: codex-p1-snapshot-retry.py PR REPO HEAD CHECK_ID fingerprint|bootstrap', file=sys.stderr)
        return 2
    pr, repo, head, lease, mode = sys.argv[1:]
    if not pr.isdigit() or '/' not in repo or not head or not lease or mode not in ('fingerprint', 'bootstrap'):
        return 2
    real_gh = shutil.which('gh')
    if not real_gh:
        print('gh is unavailable; cannot close the existing check lease', file=sys.stderr)
        return 2
    pending_out = os.environ.get(PENDING_ENV, '')
    if pending_out:
        # A stale file from an earlier run must never speak for this one.
        try:
            os.unlink(pending_out)
        except FileNotFoundError:
            pass
    start = time.monotonic()
    deadline = start + SECONDS
    messages = []
    rc = 2
    pending = False
    title = 'Codex feedback gate — evaluation failed closed'
    with tempfile.TemporaryDirectory(prefix='codex-p1-snapshot-') as tmp:
        counter = Path(tmp, 'count')
        counter.write_text('0')
        exhausted = Path(tmp, 'exhausted')
        Path(tmp, 'gh').symlink_to(Path(__file__).resolve())
        env = dict(os.environ, PATH=tmp + os.pathsep + os.environ['PATH'],
                   SNAPSHOT_REAL_GH=real_gh, SNAPSHOT_API_COUNTER=str(counter),
                   SNAPSHOT_EXHAUSTED=str(exhausted), CODEX_P1_EXPECTED_HEAD_SHA=head)
        # The gate is asked for the pending distinction only through a private
        # per-attempt file, never through anything inherited.
        env.pop(GATE_VERDICT_ENV, None)
        env.pop(PENDING_ENV, None)

        def run(command, extra_env=None):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise Exhausted('180-second recovery deadline reached')
            process = subprocess.Popen(command, env=dict(env, **(extra_env or {})), stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True, start_new_session=True)
            try:
                out, err = process.communicate(timeout=remaining)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass  # The process exited between the timeout and kill.
                process.communicate()
                raise Exhausted('180-second recovery deadline reached') from None
            if exhausted.exists():
                raise Exhausted('200 GitHub API-command budget reached')
            if err:
                messages.append(err.rstrip())
            return process.returncode, out.rstrip('\n')

        def fingerprint():
            if mode == 'bootstrap':
                return 'bootstrap-unavailable'
            status, result = run(['scripts/review-feedback-surface-fingerprint.sh', pr, repo])
            if status or not result:
                raise Unreadable('Feedback surface is unreadable; refusing snapshot recovery.')
            return result

        def pinned_head():
            status, current = run(['gh', 'api', f'repos/{repo}/pulls/{pr}', '--jq', '.head.sha'])
            if status or current != head:
                raise Unreadable('PR head moved or could not be read; refusing the original lease clearance.')

        try:
            for attempt in range(1, ATTEMPTS + 1):
                pinned_head()
                before = fingerprint()
                mark = len(messages)
                verdict_file = Path(tmp, f'verdict-{attempt}')
                gate_env = {GATE_VERDICT_ENV: str(verdict_file)} if pending_out else None
                gate_rc, output = run(['scripts/codex-p1-gate.sh', pr, repo], gate_env)
                gate_text = '\n'.join(messages[mark:] + [output])
                messages.append(f'Feedback snapshot attempt {attempt}/{ATTEMPTS}:\n{output}')
                # Configuration/read errors do not become transient just because
                # a bot also happened to edit a comment during this evaluation.
                if gate_rc not in (0, 1):
                    raise Unreadable(f'codex-p1-gate.sh exited {gate_rc} (config/usage or read error).')
                after = fingerprint()
                drift = before != after
                if not drift:
                    pinned_head()
                    # Publication fence belongs to every evaluated verdict. A
                    # failure which became clear also deserves fresh evaluation.
                    publish = fingerprint()
                    drift = publish != after
                if drift:
                    messages.append(f'Feedback changed during evaluation or before publication on attempt {attempt}; discarded stale verdict.')
                    if attempt == ATTEMPTS:
                        raise Exhausted('3 snapshot attempts exhausted')
                    if deadline - time.monotonic() <= 2:
                        raise Exhausted('180-second recovery deadline reached')
                    time.sleep(2)
                    continue
                rc = gate_rc
                title = verdict_title(gate_rc, gate_text)
                pending = bool(pending_out) and gate_rc == 1 and read_pending(verdict_file)
                if pending:
                    messages.append('Only non-blocking findings await disposition, and no blocking-tier finding is open (#2618). The lease closes red and keeps the PR blocked until the disposition exists.')
                break
        except Exhausted as error:
            rc = 3
            title = 'Codex feedback gate — snapshot recovery exhausted'
            messages.append(f'{error}. Lease fails closed; inspect reviewer activity and rerun after feedback settles. Bounds: 3 attempts, 180 seconds, 200 gh API commands (pagination shares the deadline).')
        except (Unreadable, OSError) as error:
            rc = 2
            title = 'Codex feedback gate — infra/config or head error'
            messages.append(str(error))
        except Exception as error:
            rc = 2
            messages.append(f'Unexpected evaluation error: {type(error).__name__}: {error}')

        summary = '\n'.join(messages)
        print(summary, flush=True)
        # Reserve closure outside the spent read budget. An unsuccessful PATCH
        # is not retried as success: the remote write may have happened, and a
        # later successful write must not reuse a stale snapshot after a wait.
        conclusion = 'success' if rc == 0 else 'failure'
        for close_attempt in range(3):
            command = [real_gh, 'api', '-X', 'PATCH', f'repos/{repo}/check-runs/{lease}',
                       '-f', 'status=completed', '-f', f'conclusion={conclusion}',
                       '-f', f'output[title]={title}', '-f', f'output[summary]={summary[:60000]}']
            try:
                process = subprocess.Popen(command, stdout=subprocess.DEVNULL, start_new_session=True)
                try:
                    status = process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass  # Completion after timeout cannot renew success.
                    process.wait()
                    status = 124
            except Exception as error:
                status = 1
                diagnostic = f'Lease publication attempt {close_attempt + 1}/3 failed: {type(error).__name__}: {error}'
                print(f'::error::{diagnostic}', file=sys.stderr)
                summary += '\n' + diagnostic
            if status == 0:
                if pending and rc == 1 and conclusion == 'failure':
                    try:
                        Path(pending_out).write_text('pending\n')
                    except OSError as error:
                        print(f'::warning::Could not record the pending verdict ({error}); the native run fails as before.', file=sys.stderr)
                return rc
            rc = 2
            pending = False
            conclusion = 'failure'
            title = 'Codex feedback gate — lease publication failed'
            summary += '\nPublication failed; refusing to retry an old success.'
        print(f'::error::Could not close check lease {lease}; it remains pending until a newer event or sweep supersedes it.', file=sys.stderr)
        return 2


if __name__ == '__main__':
    try:
        result = transport() if Path(sys.argv[0]).name == 'gh' else main()
    except Exception as error:
        print(f'::error::Unexpected snapshot driver error; lease closure is unconfirmed: {type(error).__name__}: {error}', file=sys.stderr)
        result = 2
    sys.exit(result)
