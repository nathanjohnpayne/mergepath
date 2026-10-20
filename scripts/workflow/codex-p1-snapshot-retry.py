#!/usr/bin/env python3
"""Evaluate and publish one existing Codex P1 lease, retrying snapshot drift.

Exit 0 clear, 1 feedback blocked, 2 unreadable/config/head failure, 3 bounded
snapshot recovery exhausted. No lease creation or identity/credential changes.
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
    start = time.monotonic()
    deadline = start + SECONDS
    messages = []
    rc = 2
    title = 'Codex feedback gate — evaluation failed closed'
    with tempfile.TemporaryDirectory(prefix='codex-p1-snapshot-') as tmp:
        counter = Path(tmp, 'count')
        counter.write_text('0')
        exhausted = Path(tmp, 'exhausted')
        Path(tmp, 'gh').symlink_to(Path(__file__).resolve())
        env = dict(os.environ, PATH=tmp + os.pathsep + os.environ['PATH'],
                   SNAPSHOT_REAL_GH=real_gh, SNAPSHOT_API_COUNTER=str(counter),
                   SNAPSHOT_EXHAUSTED=str(exhausted), CODEX_P1_EXPECTED_HEAD_SHA=head)

        def run(command):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise Exhausted('180-second recovery deadline reached')
            process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE,
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
                gate_rc, output = run(['scripts/codex-p1-gate.sh', pr, repo])
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
                return rc
            rc = 2
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
