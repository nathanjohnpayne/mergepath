#!/usr/bin/env python3
"""Execute the one native classifier from the trusted checkout, with read access.

The trusted target workflow uses this reader before acquiring its installation
credential. There is deliberately no candidate path/ref/input argument.
"""
import pathlib
import subprocess
import yaml

root = pathlib.Path(__file__).resolve().parents[2]
workflow = yaml.safe_load((root / '.github/workflows/pr-review-policy.yml').read_text())
steps = workflow['jobs']['external-review-labeling']['steps']
classifiers = [step['run'] for step in steps if step.get('id') == 'check']
if len(classifiers) != 1 or not isinstance(classifiers[0], str):
    raise SystemExit('Expected one native PR policy classifier; refusing mutation')
raise SystemExit(subprocess.run(['/bin/bash', '--noprofile', '--norc', '-e', '-o', 'pipefail',
                               '-c', classifiers[0]], stdin=subprocess.DEVNULL, cwd=root).returncode)
