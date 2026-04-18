# packaging/

Placeholder package scaffolds reserving the `mergepath` name on public
registries. See issues
[#92](https://github.com/nathanjohnpayne/mergepath/issues/92) (npm) and
[#93](https://github.com/nathanjohnpayne/mergepath/issues/93) (PyPI) for the
squatting-prevention rationale.

Both packages publish at version `0.0.0` and carry nothing but a README. They
will be replaced with real artifacts when the project cuts a first release.

## Publish — npm (`packaging/npm/`)

```bash
cd packaging/npm
npm login                    # as nathanjohnpayne
npm publish --access public
npm view mergepath           # verify: owner = nathanjohnpayne, version = 0.0.0
```

## Publish — PyPI (`packaging/pypi/`)

```bash
cd packaging/pypi
python3 -m pip install --upgrade build twine
python3 -m build             # produces dist/mergepath-0.0.0.tar.gz + .whl
python3 -m twine upload dist/*   # auth as nathanjohnpayne
```

Verify at https://pypi.org/project/mergepath/ or `pip show mergepath` after
install.

## Re-publishing

Registries forbid overwriting an existing version. To update the placeholder
README, bump to `0.0.1` (or whatever's next) in `package.json` /
`pyproject.toml` before re-publishing.
