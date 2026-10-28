#!/usr/bin/env python3
"""Reviewed PR-body parser routes and enclosing YAML bounds (#1622).

This is a bounded inventory, not a shell call graph or a whole-batch budget.
The live inventory is hub-only; copied YAML fixture controls run everywhere.
"""
from dataclasses import dataclass
from pathlib import Path
import re
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
MARGIN_SECONDS = 30
WORKFLOWS = '.github/workflows/'
TEMPLATES = '.github/templates/required-workflows/'


@dataclass(frozen=True)
class Route:
    file: str
    job: str
    step: str
    calls: int
    kind: str = 'finite'
    signature: tuple = ()


# Identities are deliberate: a renamed or removed route requires a new audit.
# Counts are maxima per evaluation for batch routes, never whole-list maxima.
ROUTES = (
    Route(WORKFLOWS+'agent-review.yml', 'assign', 'Assign reviewer identity based on Authoring-Agent', 2, signature=('parser',)),
    Route(WORKFLOWS+'pr-audit.yml', 'audit', 'Audit merged PRs for review policy compliance', 1, 'audit', ('parser',)),
    Route(WORKFLOWS+'pr-review-policy.yml', 'self-review-check', 'Validate the PR body against the contract', 1, signature=('validate',)),
    Route(WORKFLOWS+'pr-review-policy.yml', 'external-review-labeling', 'Check for external review triggers from review-policy.yml', 2, signature=('checker',)),
    Route(WORKFLOWS+'auto-clear-blocking-labels.yml', 'evaluate-and-clear', 'Re-evaluate gate per PR + remove label on pass', 2, 'batch', ('checker', 'continuation')),
    Route(WORKFLOWS+'auto-clear-blocking-labels.yml', 'evaluate-and-clear', 'Continue approved PRs after completed checks', 4, 'batch', ('continuation', 'continuation')),
    Route(WORKFLOWS+'auto-clear-blocking-labels.yml', 'scheduled-sweep', 'Re-evaluate gate per PR', 2, 'batch', ('checker', 'continuation')),
    Route(WORKFLOWS+'auto-clear-blocking-labels.yml', 'scheduled-sweep', 'Continue approved PRs after custom-workflow completions', 4, 'batch', ('continuation', 'continuation')),
    Route(WORKFLOWS+'merge-clearance-gate.yml', 'merge-clearance-gate', 'Run scripts/merge-clearance-gate.sh', 2, signature=('gate',)),
    Route(WORKFLOWS+'merge-clearance-gate.yml', 'scheduled-sweep', 'Re-evaluate gate per PR and post check_run', 2, 'batch', ('gate',)),
    Route(WORKFLOWS+'merge-clearance-gate.yml', 'dispatch-recheck', 'Re-evaluate gate for the dispatched PR and post check_run', 2, signature=('gate',)),
    Route(WORKFLOWS+'required-check-publisher.yml', 'publish', 'Resolve targets, evaluate gates, publish', 2, 'batch', ('gate',)),
    Route(TEMPLATES+'mergepath-merge-queue-authorization.yml', 'precheck', 'Evaluate the released PR and singleton queue entry', 6, signature=('group',)),
    Route(TEMPLATES+'mergepath-merge-queue-authorization.yml', 'postcheck', 'Re-evaluate every public predicate after the private audit', 3, signature=('group',)),
)


class InventoryError(ValueError):
    pass


# Scripts a step runs whose text the inventory must see as the step's own.
# The External Review Check runs the default branch's copy of the classifier
# (#2727 slice 3b); its codex-review-check.sh call is still the step's route.
DELEGATED_STEP_SCRIPTS = ('scripts/workflow/external_review_classify.sh',)


def delegated_text(text, root=ROOT):
    """Append the source of every reviewed script the step text names."""
    for path in DELEGATED_STEP_SCRIPTS:
        if path in text:
            source = root / path
            if not source.is_file():
                raise InventoryError(f'{path}: a step runs it but it is missing')
            text += '\n' + source.read_text()
    return text


def code_lines(text):
    """Discard standalone shell/JS comments; this is not a language parser."""
    return '\n'.join(line for line in text.splitlines()
                     if not line.lstrip().startswith(('#', '//')))


SCRIPT_NAMES = {
    'validate-pr-body.sh': 'validate',
    'codex-review-check.sh': 'checker',
    'merge-clearance-gate.sh': 'gate',
    'merge-group-required-checks.sh': 'group',
    'approval-merge-continuation.sh': 'continuation',
    'phase-4b-review.sh': 'phase4b',
    'post-phase-4b-handoff.sh': 'handoff',
}


def invocation_signature(text):
    """Recognize literal command positions and the one reviewed helper alias.

    Shell-entrypoint names in standalone comments, quoted diagnostics and
    file tests are data.
    Parser filenames in standalone echo/console.log quoted literals are data;
    other parser operands remain conservative, including unsupported dynamic
    indirection. This is not a general shell/JavaScript parser.
    """
    text = code_lines(text)
    found = []
    for line in text.splitlines():
        literal = r'''(?:'[^']*'|"(?:\\.|[^"\\])*")'''
        shell_diagnostic = re.fullmatch(r'\s*echo\s+' + literal + r'\s*;?\s*(?:#.*)?', line)
        js_diagnostic = re.fullmatch(r'\s*console\.log\(\s*' + literal + r'\s*\)\s*;?\s*(?://.*)?', line)
        # A double-quoted shell operand can still execute a substitution.
        diagnostic = js_diagnostic or (shell_diagnostic and '$(' not in line and '`' not in line)
        if not diagnostic:
            found.extend(['parser'] * line.count('pr-body-contract.mjs'))
        # Protect quoted diagnostic operands and trailing comments from the
        # control-prefix admission below. A literal $(...) boundary still
        # starts a command inside double quotes; this is no shell evaluator.
        inert = tuple(re.finditer(r"""'[^']*'|"(?:\\.|[^"\\])*"|(?<!\S)\#.*""", line))
        for name, key in SCRIPT_NAMES.items():
            # A shell command, optionally inside command substitution, after
            # bash, or through the publisher's reviewed gate function.
            path = r'["\']?[^\s"\']*scripts/(?:workflow/)?' + re.escape(name) + r'["\']?'
            direct = (r'(?P<direct_boundary>^\s*|[|;&]\s*|(?<!\\)\$\(\s*(?:(?:bash|gate)\s+)?|\b(?:bash|gate)\s+)'
                      + r'(?P<direct_path>' + path + r')(?=\s|[;|&)]|$)')
            # The added branch requires a control prefix, preserving the
            # existing direct-call admission rather than widening every word.
            controlled = (r'(?P<boundary>^\s*|[|;&]\s*|\$\(\s*)'
                          r'(?P<control>(?:(?:if|elif|while|until|then|else|do|!)\s+)+)'
                          + r'(?P<controlled_path>' + path + r')(?=\s|[;|&)]|$)')
            command = re.compile(direct + '|' + controlled)
            for match in command.finditer(line):
                boundary = 'boundary' if match['control'] else 'direct_boundary'
                path_group = 'controlled_path' if match['control'] else 'direct_path'
                enclosing = next((span for span in inert
                                  if span.start() <= match.start() < span.end()), None)
                if enclosing:
                    quoted_executable = match.start(path_group) == enclosing.start()
                    substitution = (enclosing[0].startswith('"')
                                    and match[boundary].lstrip().startswith('$(')
                                    and (match.start() == 0 or line[match.start()-1] != '\\'))
                    if not (quoted_executable or substitution):
                        continue
                found.append(key)
    if re.search(r'CLEARANCE_HELPER=.*scripts/codex-review-check\.sh', text):
        found.extend(['checker'] * len(re.findall(r'bash\s+"\$CLEARANCE_HELPER"', text)))
    # A wrapper's API/comment writes only source the library. PR-create is the
    # actual parser branch; source/file references alone do not count.
    if re.search(r'gh-as-author\.sh[^\n]*\bpr\s+(?:create|new)\b', text):
        found.append('author-create')
    return tuple(sorted(found))


def minutes(value, context, default=None):
    if value is None:
        return default
    if type(value) is not int or value <= 0:
        raise InventoryError(f'{context}: unsupported timeout-minutes {value!r}; need a positive integer')
    return value * 60


def audit_documents(documents, routes, seconds):
    """Audit parsed jobs/steps and reject uncovered literal runtime routes."""
    expected = {(r.file, r.job, r.step): r for r in routes}
    seen = set()
    rows = []
    for file, document in documents.items():
        jobs = document.get('jobs', {})
        if not isinstance(jobs, dict):
            raise InventoryError(f'{file}: jobs must be a mapping')
        for job_id, job in jobs.items():
            if not isinstance(job, dict):
                raise InventoryError(f'{file}/{job_id}: unsupported job')
            for step in job.get('steps', []):
                text = delegated_text(step.get('run', '') + '\n' + step.get('with', {}).get('script', ''))
                signature = invocation_signature(text)
                identity = (file, job_id, step.get('name', ''))
                route = expected.get(identity)
                if not signature and route is None:
                    continue
                if route is None:
                    raise InventoryError(f'{file}/{job_id}/{identity[2]}: unenumerated parser route {signature}')
                if identity in seen:
                    raise InventoryError(f'{identity}: duplicate route identity')
                seen.add(identity)
                if signature != tuple(sorted(route.signature)):
                    raise InventoryError(f'{identity}: runtime call signature changed: {signature}')
                if 'continuation' in route.signature and text.count('--retract-unsafe-only') != 1:
                    raise InventoryError(f'{identity}: protective-only continuation branch changed; re-audit calls')
                if route.signature == ('validate',) and '--self-review-only' not in text:
                    raise InventoryError(f'{identity}: validator mode changed; re-audit sequential calls')
                if route.signature == ('group',):
                    phase = 'pre-audit' if route.job == 'precheck' else 'post-audit'
                    if '--phase '+phase not in text:
                        raise InventoryError(f'{identity}: required-template phase changed; re-audit calls')
                job_seconds = minutes(job.get('timeout-minutes'), str(identity)+' job', 360*60)
                step_seconds = minutes(step.get('timeout-minutes'), str(identity)+' step', job_seconds)
                floor = route.calls * seconds + MARGIN_SECONDS
                if route.kind == 'audit':
                    # #1613 intentionally clamps parser/verifier/API work to a
                    # shared deadline. Its reporting reserve is inside 25min.
                    for marker in ('Date.now() + 25 * 60 * 1000',
                                   'AUDIT_REPORT_RESERVE_MS = 60000',
                                   'timeout: auditTimeout(PR_BODY_PARSE_TIMEOUT_MS)',
                                   'Math.min(maximum, auditRemainingMs())'):
                        if marker not in text:
                            raise InventoryError(f'{identity}: accepted audit deadline/clamp drifted: {marker}')
                    floor = 25*60 + MARGIN_SECONDS
                if min(job_seconds, step_seconds) <= floor:
                    raise InventoryError(f'{identity}: enclosing bound {min(job_seconds, step_seconds)}s '
                                         f'must exceed floor {floor}s ({route.calls} calls, {route.kind})')
                rows.append((identity, route.kind, route.calls, job_seconds, step_seconds, floor))
    missing = set(expected) - seen
    if missing:
        raise InventoryError(f'missing or renamed parser route: {sorted(missing)!r}')
    return rows


def read_documents(root):
    result = {}
    for folder in (WORKFLOWS, TEMPLATES):
        for file in sorted((root / folder).rglob('*')):
            if file.suffix in ('.yml', '.yaml'):
                result[file.relative_to(root).as_posix()] = yaml.safe_load(file.read_text())
    return result



def shell_helper_calls(source, helper):
    source = code_lines(source)
    return sum(len(re.findall(r'\b' + re.escape(helper) + r'(?=\s|\(|$)', line))
               for line in source.splitlines()
               if not re.match(r'\s*' + re.escape(helper) + r'\s*\(\)', line))


def source_budgets(root):
    """Count the reviewed helper edges, without inferring a shell call graph.

    Branch multiplicity is explicit. Source changes that add a parser helper
    or revalidation must update the route audit rather than retain old counts.
    """
    def read(path):
        return code_lines((root/path).read_text())

    library = read('scripts/lib/pr-body-contract.sh')
    validate = library.split('pr_body_validate() {', 1)[1]
    helpers = ('pr_body_authoring_agent_count', 'pr_body_authoring_agent', 'pr_body_has_self_review')
    validation_calls = sum(shell_helper_calls(validate, helper) for helper in helpers)
    checker = read('scripts/codex-review-check.sh')
    checker_calls = (sum(shell_helper_calls(checker, helper) for helper in helpers)
                     + validation_calls * shell_helper_calls(checker, 'pr_body_validate'))
    group_source = read('scripts/workflow/merge-group-required-checks.sh')
    group = group_source.rsplit('case "$PHASE" in', 1)[1]
    pre = group.split('pre-audit)', 1)[1].split('post-audit)', 1)[0]
    post = group.split('post-audit)', 1)[1]
    # One --self-review-only call and one conditional external checker in each
    # run_all_predicates, twice in pre-audit and once in post-audit.
    predicates = group_source.split('run_all_predicates() {', 1)[1].split('\n}', 1)[0]
    predicate_edges = invocation_signature(predicates)
    if set(predicate_edges) - {'validate', 'gate'}:
        raise InventoryError('required-template predicate edges changed; re-audit calls')
    group_calls = predicate_edges.count('validate') + checker_calls * predicate_edges.count('gate')
    continuation_edges = invocation_signature(read('scripts/workflow/approval-merge-continuation.sh'))
    if set(continuation_edges) != {'checker', 'gate'}:
        raise InventoryError('continuation runtime edges changed; re-audit parser cardinality')
    phase = read('scripts/phase-4b-review.sh')
    if shell_helper_calls(phase, 'pr_body_validate') != 2 or shell_helper_calls(phase, 'pr_body_authoring_agent') != 2:
        raise InventoryError('Phase 4b initial/revalidation helper edges changed; re-audit calls')
    phase_calls = (validation_calls + 1) * (1 + shell_helper_calls(phase, 'revalidate_pr_body_author'))
    return {
        'validate': validation_calls,
        'self-review': 1,
        'print-author': validation_calls + 1,
        'checker': checker_calls,
        'gate': checker_calls,
        # Stable-policy continuation parses zero bodies: shared author exits,
        # other authors skip the checker's parser. Retain the four-allowance
        # delegation ceiling as protection, not an attainable stable count.
        'continuation': len(continuation_edges) * checker_calls,
        'group-pre': group_calls * shell_helper_calls(pre, 'run_all_predicates'),
        'group-post': group_calls * shell_helper_calls(post, 'run_all_predicates'),
        'phase4b': phase_calls,
        'handoff': sum(shell_helper_calls(read('scripts/post-phase-4b-handoff.sh'), helper) for helper in helpers),
        'author-create': validation_calls,
    }


def fixture(calls=1, step_timeout=None, job_timeout=None, template=False):
    file = (TEMPLATES if template else WORKFLOWS)+'fixture.yml'
    text = 'node scripts/lib/pr-body-contract.mjs --json\n' * calls
    job = {'steps': [{'name': 'Parse body', 'run': text}]}
    if step_timeout is not None:
        job['steps'][0]['timeout-minutes'] = step_timeout
    if job_timeout is not None:
        job['timeout-minutes'] = job_timeout
    # Round-trip through YAML so controls exercise the same parsed structure.
    return {file: yaml.safe_load(yaml.safe_dump({'jobs': {'parse': job}}))}, (
        Route(file, 'parse', 'Parse body', calls, signature=('parser',)*calls),)


class WorkflowBounds(unittest.TestCase):
    def test_default_job_and_absent_step(self):
        docs, routes = fixture()
        self.assertEqual(audit_documents(docs, routes, 120)[0][3:5], (21600, 21600))

    def test_one_call_one_minute_refuses(self):
        docs, routes = fixture(step_timeout=1)
        with self.assertRaisesRegex(InventoryError, 'enclosing.*floor'):
            audit_documents(docs, routes, 120)

    def test_two_calls_four_minutes_refuses(self):
        for kwargs in ({'step_timeout': 4}, {'job_timeout': 4}):
            with self.subTest(kwargs=kwargs):
                docs, routes = fixture(calls=2, **kwargs)
                with self.assertRaisesRegex(InventoryError, 'enclosing.*floor'):
                    audit_documents(docs, routes, 120)

    def test_margin_equality_refuses(self):
        # A 90s fixture bound makes one minute + 30s margin exactly 120s.
        docs, routes = fixture(step_timeout=2)
        with self.assertRaisesRegex(InventoryError, 'enclosing.*floor'):
            audit_documents(docs, routes, 90)

    def test_long_job_short_step_refuses(self):
        docs, routes = fixture(step_timeout=1, job_timeout=30)
        with self.assertRaisesRegex(InventoryError, 'enclosing.*floor'):
            audit_documents(docs, routes, 120)

    def test_sufficient_declared_bounds(self):
        docs, routes = fixture(calls=2, step_timeout=5, job_timeout=6)
        self.assertEqual(len(audit_documents(docs, routes, 120)), 1)

    def test_dynamic_and_invalid_timeouts_refuse(self):
        for value in ('${{ inputs.minutes }}', 0, -1, True, 1.5):
            with self.subTest(value=value):
                docs, routes = fixture(step_timeout=value)
                with self.assertRaisesRegex(InventoryError, 'unsupported timeout-minutes'):
                    audit_documents(docs, routes, 120)

    def test_required_template_is_included(self):
        docs, routes = fixture(step_timeout=1, template=True)
        with self.assertRaisesRegex(InventoryError, 'enclosing.*floor'):
            audit_documents(docs, routes, 120)

    def test_renamed_and_alias_jobs_refuse(self):
        docs, routes = fixture(template=True)
        file = next(iter(docs))
        job = docs[file]['jobs'].pop('parse')
        docs[file]['jobs']['renamed'] = job
        with self.assertRaisesRegex(InventoryError, 'unenumerated parser route'):
            audit_documents(docs, routes, 120)
        docs[file] = yaml.safe_load('jobs:\n  parse: &job\n    steps:\n      - name: Parse body\n        run: node scripts/lib/pr-body-contract.mjs --json\n  alias: *job\n')
        with self.assertRaisesRegex(InventoryError, 'unenumerated parser route'):
            audit_documents(docs, routes, 120)

    def test_removed_route_refuses(self):
        docs, routes = fixture()
        docs[next(iter(docs))]['jobs']['parse']['steps'] = []
        with self.assertRaisesRegex(InventoryError, 'missing or renamed'):
            audit_documents(docs, routes, 120)

    def test_new_direct_runtime_call_refuses(self):
        docs, routes = fixture()
        docs[next(iter(docs))]['jobs']['parse']['steps'].append(
            {'name': 'New parser', 'run': 'node scripts/lib/pr-body-contract.mjs --author'})
        with self.assertRaisesRegex(InventoryError, 'unenumerated parser route'):
            audit_documents(docs, routes, 120)

    def test_control_keyword_runtime_calls_require_classification(self):
        forms = (
            'if {call}; then :; fi',
            'if false; then :; elif {call}; then :; fi',
            'while {call}; do break; done',
            'until {call}; do break; done',
            'if true; then {call}; fi',
            'if false; then :; else {call}; fi',
            'for value in one; do {call}; done',
            '! {call}',
            'if ! {call}; then :; fi',
            'if "{call}"; then :; fi',
            'true && ! {call}',
            'false || if {call}; then :; fi',
            'result="$(if {call}; then :; fi)"',
        )
        for name, key in SCRIPT_NAMES.items():
            folder = 'workflow/' if key in ('group', 'continuation') else ''
            call = 'scripts/' + folder + name
            for form in forms:
                run = form.format(call=call)
                with self.subTest(run=run):
                    docs, routes = fixture()
                    docs[next(iter(docs))]['jobs']['parse']['steps'].append(
                        {'name': 'New conditional parser', 'run': run})
                    with self.assertRaisesRegex(InventoryError, 'unenumerated parser route'):
                        audit_documents(docs, routes, 120)
                    self.assertEqual(invocation_signature(run), (key,))

    def test_control_keyword_references_are_not_shell_calls(self):
        references = (
            '# if scripts/validate-pr-body.sh; then :; fi',
            ': # if scripts/validate-pr-body.sh; then :; fi',
            'echo "if scripts/validate-pr-body.sh; then :; fi"',
            "echo 'while scripts/validate-pr-body.sh; do :; done'",
            "printf '%s\\n' 'failure; if scripts/validate-pr-body.sh; then :; fi'",
            'echo "failure; ! scripts/validate-pr-body.sh"',
            "echo '$(if scripts/validate-pr-body.sh; then :; fi)'",
            'echo if scripts/validate-pr-body.sh',
            'test -f scripts/validate-pr-body.sh',
            'if [ -f scripts/validate-pr-body.sh ]; then :; fi',
        )
        for run in references:
            with self.subTest(run=run):
                self.assertEqual(invocation_signature(run), ())

    def test_boolean_and_and_quoted_command_positions(self):
        forms = ('true && {call} --check', 'true && "{call}" --check',
                 'false || {call} --check', "'{call}' --check",
                 'bash "{call}" --check', 'result=$({call} --check)',
                 'echo "$({call} --check)"', 'echo "$(bash {call} --check)"')
        for name, key in SCRIPT_NAMES.items():
            folder = 'workflow/' if key in ('group', 'continuation') else ''
            call = 'scripts/' + folder + name
            flags = {'validate': '--self-review-only', 'continuation': '--retract-unsafe-only',
                     'group': '--phase post-audit'}.get(key, '--check')
            for form in forms:
                run = form.format(call=call).replace('--check', flags)
                with self.subTest(run=run):
                    self.assertEqual(invocation_signature(run), (key,))
                    docs, _ = fixture(step_timeout=1)
                    file = next(iter(docs))
                    docs[file]['jobs']['parse']['steps'][0]['run'] = run
                    with self.assertRaisesRegex(InventoryError, 'unenumerated parser route'):
                        audit_documents(docs, (), 120)
                    route = Route(file, 'parse', 'Parse body', 1, signature=(key,))
                    with self.assertRaisesRegex(InventoryError, 'enclosing.*floor'):
                        audit_documents(docs, (route,), 120)

    def test_quoted_boolean_separators_remain_data(self):
        forms = ('echo "true && {call} --check"',
                 "printf '%s\\n' 'true && {call} --check'",
                 'echo "bash {call} --check"',
                 "echo '$({call} --check)'", 'echo "\\$({call} --check)"',
                 'true # && {call} --check')
        for name in SCRIPT_NAMES:
            for form in forms:
                run = form.format(call='scripts/' + name)
                with self.subTest(run=run):
                    self.assertEqual(invocation_signature(run), ())

    def test_standalone_parser_filename_diagnostics_are_data(self):
        path = 'scripts/lib/pr-body-contract.mjs'
        diagnostics = (f'echo "{path}"', f"echo '{path}'", f'echo "{path}; literal && data"',
                       f"console.log('{path}')", f'console.log("{path}");')
        for run in diagnostics:
            with self.subTest(run=run):
                self.assertEqual(invocation_signature(run), ())
                docs, _ = fixture()
                docs[next(iter(docs))]['jobs']['parse']['steps'][0]['run'] = run
                self.assertEqual(audit_documents(docs, (), 120), [])
        for run in (f"execFileSync('node', ['{path}', '--json']);",
                    f"console.log(execFileSync('node', ['{path}']));",
                    f'echo "$(node {path} --json)"',
                    f"const parser = '{path}'; runParser(parser);"):
            with self.subTest(run=run):
                self.assertEqual(invocation_signature(run), ('parser',))

    def test_added_sequential_call_requires_reaudit(self):
        docs, routes = fixture()
        step = docs[next(iter(docs))]['jobs']['parse']['steps'][0]
        step['run'] += 'node scripts/lib/pr-body-contract.mjs --author\n'
        with self.assertRaisesRegex(InventoryError, 'runtime call signature changed'):
            audit_documents(docs, routes, 120)

    def test_same_line_sequential_direct_calls_require_reaudit(self):
        docs, routes = fixture()
        step = docs[next(iter(docs))]['jobs']['parse']['steps'][0]
        step['run'] = step['run'].strip() + '; node scripts/lib/pr-body-contract.mjs --author\n'
        with self.assertRaisesRegex(InventoryError, 'runtime call signature changed'):
            audit_documents(docs, routes, 120)

    def test_yaml_merge_key_timeout_is_effective(self):
        docs, routes = fixture()
        file = next(iter(docs))
        docs[file] = yaml.safe_load('''defaults: &bounds
  timeout-minutes: 1
jobs:
  parse:
    timeout-minutes: 30
    steps:
      - <<: *bounds
        name: Parse body
        run: node scripts/lib/pr-body-contract.mjs --json
''')
        with self.assertRaisesRegex(InventoryError, 'enclosing.*floor'):
            audit_documents(docs, routes, 120)

    def test_accepted_dynamic_audit_deadline_and_clamp(self):
        docs, routes = fixture(job_timeout=30)
        file = next(iter(docs))
        step = docs[file]['jobs']['parse']['steps'][0]
        step['run'] += '''
const AUDIT_DEADLINE_MS = Date.now() + 25 * 60 * 1000;
const AUDIT_REPORT_RESERVE_MS = 60000;
const options = {timeout: auditTimeout(PR_BODY_PARSE_TIMEOUT_MS)};
return Math.min(maximum, auditRemainingMs());
'''
        routes = (Route(file, 'parse', 'Parse body', 1, 'audit', ('parser',)),)
        self.assertEqual(audit_documents(docs, routes, 120)[0][-1], 1530)
        step['run'] = step['run'].replace('Math.min(maximum, auditRemainingMs())', 'maximum')
        with self.assertRaisesRegex(InventoryError, 'audit deadline/clamp drifted'):
            audit_documents(docs, routes, 120)

    def test_references_are_not_shell_calls(self):
        self.assertEqual(invocation_signature('''# scripts/codex-review-check.sh
// scripts/lib/pr-body-contract.mjs
if [ -f scripts/codex-review-check.sh ]; then
  echo 'scripts/merge-clearance-gate.sh failed'
fi
scripts/gh-as-author.sh -- gh api repos/owner/repo
'''), ())

    @unittest.skipUnless((ROOT/'scripts/sync-to-downstream.sh').is_file(), 'hub-only actual workflow mutations')
    def test_actual_assignment_step_floor_mutation(self):
        documents = read_documents(ROOT)
        route = ROUTES[0]
        job = documents[route.file]['jobs'][route.job]
        step = next(st for st in job['steps'] if st.get('name') == route.step)
        step['timeout-minutes'] = 4
        with self.assertRaisesRegex(InventoryError, 'enclosing.*floor 270s'):
            audit_documents(documents, ROUTES, 120)

    @unittest.skipUnless((ROOT/'scripts/sync-to-downstream.sh').is_file(), 'hub-only live workflow/template inventory')
    def test_live_inventory(self):
        shell = (ROOT/'scripts/lib/pr-body-contract.sh').read_text()
        values = re.findall(r'^PR_BODY_CONTRACT_TIMEOUT_SECONDS=([0-9]+)$', shell, re.M)
        self.assertEqual(len(values), 1, 'parser maximum must be one literal constant')
        self.assertGreater(int(values[0]), 0)
        documents = read_documents(ROOT)
        budgets = source_budgets(ROOT)
        self.assertEqual({k: budgets[k] for k in ('validate', 'print-author', 'checker', 'phase4b', 'handoff')},
                         {'validate': 3, 'print-author': 4, 'checker': 2, 'phase4b': 12, 'handoff': 2})
        for route in ROUTES:
            key = route.signature[0]
            if key == 'group':
                key += '-pre' if route.job == 'precheck' else '-post'
            if key == 'parser':
                job = documents[route.file]['jobs'][route.job]
                text = next(st['with']['script'] for st in job['steps'] if st.get('name') == route.step)
                count = 1 if route.kind == 'audit' else len(re.findall(r"runParser\(['\"]--", code_lines(text)))
                self.assertEqual(route.calls, count, f'{route}: direct sequential call count drifted')
            else:
                self.assertEqual(route.calls, budgets['self-review' if key == 'validate' else key],
                                 f'{route}: shared helper count drifted')
        rows = audit_documents(documents, ROUTES, int(values[0]))
        print(f'Live enclosing-bound inventory: {len(rows)} reviewed production routes', flush=True)


if __name__ == '__main__':
    unittest.main(verbosity=2)
