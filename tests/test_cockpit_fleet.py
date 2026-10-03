"""Hermetic Fleet source/caller tests. Expected <10s; outer bound90s."""

import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from mergepath.cockpit.fleet import FleetProvider, parse_audit, MAX_STDOUT, MAX_STDERR
from mergepath.cockpit.github import ClientError
from mergepath.cockpit.inventory import Repository
from mergepath.cockpit.scheduler import Scheduler

INVENTORY = (Repository("hub", "fixture/hub", True),
             Repository("one", "fixture/one"), Repository("two", "fixture/two"))
STAMP = "2026-10-03T19:00:00Z"


def record(entry=INVENTORY[1], status="in-sync", stamp=STAMP):
    direction = {"drift": "hub ahead", "ahead": "consumer ahead of hub", "override-only": "covered by .sync-overrides.yml"}.get(status)
    return {"schema_version": 1, "name": entry.name, "repo": entry.repo, "visibility": "public",
            "baseline": "main@" + "a" * 40,
            "baseline_info": {"ref": "main", "sha": "a" * 40, "kind": "cache-clone", "refreshed": True, "dirty": False, "warnings": []},
            "hub_sha": "b" * 40, "status": status,
            "paths": [{"path": "scripts/a.sh", "class": "kit", "direction": direction,
                       "comparison": "drift:4", "override_reason": "owner overlay" if status == "override-only" else None,
                       "provenance": None}] if direction else [],
            "open_sync_prs": None if status == "fetch-error" else [],
            "error": {"source": "consumer", "reason": "clone unavailable"} if status == "fetch-error" else None,
            "audited_at": stamp}


def ndjson(records):
    return ("".join(json.dumps(r) + "\n" for r in records)).encode()


class SourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="test-fleet-")
        self.directory = Path(self.temp.name)
        self.hub = self.directory / "hub"
        (self.hub / "scripts").mkdir(parents=True)
        self.script = self.hub / "scripts/sync-to-downstream.sh"
        self.script.write_text("#!/bin/bash\nexit 2\n")
        self.providers = []

    def tearDown(self):
        for provider in self.providers:
            if provider.workspace.exists():
                provider.close()
        self.temp.cleanup()

    def provider(self, token="review-fixture", utilities=None):
        provider = FleetProvider(INVENTORY, self.hub, token, cache_parent=self.directory,
                                 utilities=utilities or {t: shutil.which(t) for t in ("bash", "git", "gh")})
        self.providers.append(provider)
        return provider

    def fetch(self, provider, records, code=0):
        with patch.object(provider, "_run", return_value=(code, ndjson(records))):
            return provider.fetch(time.monotonic() + 5).data

    def assert_category(self, expected, function):
        with self.assertRaises(ClientError) as caught:
            function()
        self.assertEqual(caught.exception.category, expected)

    def test_complete_five_statuses_and_exit_precedence(self):
        for status, code in [("in-sync", 0), ("override-only", 0), ("drift", 1), ("ahead", 1), ("fetch-error", 3)]:
            with self.subTest(status=status):
                records = [record(status=status), record(INVENTORY[2])]
                self.assertEqual(parse_audit(ndjson(records), code, INVENTORY)[0]["status"], status)
        ahead = record(status="ahead")
        ahead["paths"].append(record(status="drift")["paths"][0] | {"path": "AGENTS.md", "class": "canonical"})
        ahead["paths"].append(record(status="override-only")["paths"][0] | {"path": "overlay.md"})
        self.assertEqual(parse_audit(ndjson([ahead, record(INVENTORY[2])]), 1, INVENTORY)[0], ahead)

    def test_framing_identity_shape_and_incoherent_status_fail_whole_snapshot(self):
        good = [record(), record(INVENTORY[2])]
        bad = copy.deepcopy(good); bad[1]["repo"] = "foreign/two"
        wrong = copy.deepcopy(good); wrong[0]["baseline_info"]["kind"] = "local-tree"
        fake = copy.deepcopy(good); fake[0]["status"] = "ahead"
        for value, code in [(ndjson(good[:1]), 0), (ndjson([good[0], good[0]]), 0), (ndjson(bad), 0),
                            (ndjson(wrong), 0), (ndjson(fake), 1), (ndjson(good).rstrip(), 0),
                            (b'{"repo":"fixture/one","repo":"fixture/two"}\n', 0),
                            (b"not json\n", 0), (ndjson(good), 3), (ndjson(good), 2)]:
            with self.subTest(value=value[:50], code=code), self.assertRaises(ClientError):
                parse_audit(value, code, INVENTORY)

    def test_ndjson_uses_literal_lf_not_unicode_text_separators(self):
        for separator in ("\u0085", "\u2028", "\u2029"):
            with self.subTest(separator=repr(separator)):
                first = record(status="override-only")
                first["paths"][0].update(path="docs/a" + separator + "b.md", override_reason="overlay" + separator + "reason")
                first["open_sync_prs"] = [{"number": 88, "branch": "mergepath-sync/a" + separator + "b",
                                          "state": "UNKNOWN", "lifecycle_state": "OPEN", "draft": False}]
                records = [first, record(INVENTORY[2])]
                output = ("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in records)).encode()
                self.assertEqual(parse_audit(output, 0, INVENTORY), records)
        good = ndjson([record(), record(INVENTORY[2])])
        for output in (good[:-1], good + b"\n", good.replace(b"\n", b"\xe2\x80\xa8")):
            with self.subTest(output=output[-20:]), self.assertRaises(ClientError):
                parse_audit(output, 0, INVENTORY)

    def test_row_retention_independent_time_recovery_and_unavailable_pr_lookup(self):
        provider = self.provider()
        first = record(); first["open_sync_prs"] = [{"number": 88, "branch": "mergepath-sync/x", "state": "UNKNOWN", "lifecycle_state": "OPEN", "draft": True}]
        initial = self.fetch(provider, [first, record(INVENTORY[2])])
        failed = record(status="fetch-error", stamp="2026-10-03T19:01:00Z")
        second = record(INVENTORY[2], status="drift", stamp="2026-10-03T19:01:00Z")
        partial = self.fetch(provider, [failed, second], 3)
        row = partial["repositories"][0]
        self.assertEqual(row["record"], first)
        self.assertEqual(row["observed_at"], initial["repositories"][0]["observed_at"])
        self.assertGreater(row["attempted_at"], row["observed_at"])
        self.assertTrue(row["stale"])
        self.assertEqual(row["status"], "fetch-error")
        self.assertIsNone(row["attempt"]["open_sync_prs"])
        self.assertFalse(partial["complete"])
        self.assertGreater(partial["repositories"][1]["observed_at"], row["observed_at"])
        fallback = row["sync_pr_rows"][0]
        self.assertEqual(fallback["head"], None)
        self.assertTrue(fallback["partial"])
        self.assertEqual(fallback["hazards"], [])
        self.assertTrue(all(b["remaining"] is None for b in fallback["budgets"]))
        recovered = self.fetch(provider, [record(stamp="2026-10-03T19:02:00Z"), second], 1)
        self.assertTrue(recovered["complete"])
        self.assertFalse(recovered["repositories"][0]["stale"])
        self.assertEqual(recovered["repositories"][0]["record"]["open_sync_prs"], [])
        fresh = self.provider()
        unknown = self.fetch(fresh, [failed, second], 3)["repositories"][0]
        self.assertIsNone(unknown["record"])
        self.assertIsNone(unknown["observed_at"])

    def test_fatal_attempt_does_not_change_last_good(self):
        provider = self.provider()
        self.fetch(provider, [record(), record(INVENTORY[2])])
        previous = copy.deepcopy(provider._last)
        with patch.object(provider, "_run", return_value=(2, ndjson([record(status="drift")]))):
            self.assert_category("source_failed", lambda: provider.fetch(time.monotonic() + 5))
        self.assertEqual(provider._last, previous)

    def test_total_deadline_covers_projection_before_last_good_commit(self):
        provider = self.provider()
        self.fetch(provider, [record(), record(INVENTORY[2])])
        previous = copy.deepcopy(provider._last)
        clock = [1000.0]; provider.monotonic = lambda: clock[0]
        observed = record()
        observed["open_sync_prs"] = [{"number": 88, "branch": "mergepath-sync/x", "state": "UNKNOWN", "lifecycle_state": "OPEN", "draft": False}]
        from mergepath.cockpit.prs import partial_row
        def late_row(*args, **kwargs):
            clock[0] = 1200
            return partial_row(*args, **kwargs)
        with patch.object(provider, "_run", return_value=(0, ndjson([observed, record(INVENTORY[2])]))), patch("mergepath.cockpit.fleet.partial_row", side_effect=late_row):
            self.assert_category("deadline_exceeded", lambda: provider.fetch(2000))
        self.assertEqual(provider._last, previous)

    def test_missing_reviewer_refuses_before_spawn_and_ambient_credentials_are_absent(self):
        provider = self.provider(None)
        with patch.object(provider, "_run") as run:
            self.assert_category("cached_reviewer_credential_required", lambda: provider.fetch(time.monotonic() + 5))
            run.assert_not_called()
        hostile = {"GH_TOKEN": "author", "GITHUB_TOKEN": "other", "OP_PREFLIGHT_AUTHOR_PAT": "author", "SSH_AUTH_SOCK": "socket",
                   "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "credential.helper", "GIT_CONFIG_VALUE_0": "evil", "HTTPS_PROXY": "proxy", "GH_DEBUG": "api"}
        with patch.dict(os.environ, hostile):
            env = self.provider()._environment()
        self.assertEqual(env["GH_TOKEN"], "review-fixture")
        for name in hostile.keys() - {"GH_TOKEN", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0"}:
            self.assertNotIn(name, env)
        self.assertEqual(env["GIT_CONFIG_VALUE_0"], "")
        self.assertEqual(env["GIT_CONFIG_GLOBAL"], os.devnull)
        self.assertEqual(env["GIT_TERMINAL_PROMPT"], "0")
        self.assertEqual((self.providers[-1].workspace.stat().st_mode & 0o777), 0o700)
        self.assertNotEqual(self.providers[-1].cache, self.provider().cache)

    def test_constructor_failure_cleans_its_partial_workspace_and_close_is_idempotent(self):
        before = set(self.directory.iterdir())
        with patch.object(Path, "symlink_to", side_effect=OSError("fixture failure")), self.assertRaises(OSError):
            self.provider()
        self.assertEqual(set(self.directory.iterdir()), before)
        provider = self.provider(); provider.close(); provider.close()
        self.assertFalse(provider.workspace.exists())

    def seed_cache(self, provider, origin="https://github.com/fixture/one.git", extra=""):
        gitdir = provider.cache / "one/.git"
        gitdir.mkdir(parents=True)
        (gitdir / "config").write_text('[core]\n repositoryformatversion = 0\n bare = false\n[remote "origin"]\n url = ' + origin + '\n fetch = +refs/heads/main:refs/remotes/origin/main\n' + extra)
        return gitdir

    def test_unsafe_cache_origins_configs_paths_and_gitdir_links_refuse_before_spawn(self):
        cases = [("ssh://github.com/fixture/one", ""), ("https://github.com/foreign/repo.git", ""),
                 ("https://review:secret@github.com/fixture/one", ""), ("https://github.com/fixture/one.git", '[include]\n path = /private/config\n'),
                 ("https://github.com/fixture/one.git", '[core]\n fsmonitor = evil\n')]
        for origin, extra in cases:
            provider = self.provider(); self.seed_cache(provider, origin, extra)
            with patch.object(provider, "_run") as run:
                self.assert_category("source_failed", lambda: provider.fetch(time.monotonic() + 5)); run.assert_not_called()
        provider = self.provider(); gitdir = self.seed_cache(provider)
        (gitdir / "index").symlink_to(self.script)
        self.assert_category("source_failed", lambda: provider.fetch(time.monotonic() + 5))
        provider = self.provider(); (provider.cache / "one").symlink_to(self.hub)
        self.assert_category("source_failed", lambda: provider.fetch(time.monotonic() + 5))
        provider = self.provider(); (provider.cache / "unexpected").mkdir()
        self.assert_category("source_failed", lambda: provider.fetch(time.monotonic() + 5))

    def test_real_process_caps_timeout_group_cleanup_and_denied_no_raw_stderr(self):
        provider = self.provider()
        self.script.write_text("#!/bin/bash\nprintf 'must-not-leak-secret' >&2\nexit 3\n")
        self.assert_category("invalid_upstream_json", lambda: provider.fetch(time.monotonic() + 5))
        for cap, stream in [(MAX_STDOUT, 1), (MAX_STDERR, 2)]:
            # Fixed bash invokes the trusted script, so use shell->Python fixture.
            self.script.write_text(f'#!/bin/bash\nexec {shlex_quote(sys.executable)} -c \'import os;os.write({stream},b"x"*{cap + 1})\'\n')
            self.assert_category("response_too_large", lambda: provider.fetch(time.monotonic() + 5))
        pidfile = provider.workspace / "tmp/child-pid"
        program = 'import subprocess; p=subprocess.Popen(["/bin/sleep","30"]);open(' + repr(str(pidfile)) + ',"w").write(str(p.pid))'
        self.script.write_text('#!/bin/bash\n' + shlex_quote(sys.executable) + ' -c ' + shlex_quote(program) + '\n')
        start = time.monotonic()
        self.assert_category("deadline_exceeded", lambda: provider.fetch(start + .2))
        self.assertLess(time.monotonic() - start, 2)
        pid = pidfile.read_text()
        probe = subprocess.run(["ps", "-p", pid, "-o", "stat="], capture_output=True, text=True)
        self.assertTrue(probe.returncode == 1 or not probe.stdout.strip() or probe.stdout.strip().startswith("Z"))
        self.assertIsNone(provider._process)

    def test_scheduler_refresh_coalesces_and_failure_backoff_retains_envelope(self):
        gate = threading.Event(); calls = []
        def fetch(deadline):
            calls.append(deadline); gate.wait(1)
            raise ClientError("source_failed")
        now = [0.0]
        scheduler = Scheduler(monotonic=lambda: now[0], clock=lambda: 1000 + now[0])
        scheduler.register("fleet", fetch, hot_interval=1800, idle_interval=1800, timeout=180, max_backoff=7200)
        scheduler.tick()
        for _ in range(20): scheduler.refresh("fleet"); scheduler.tick()
        self.assertEqual(len(calls), 1)
        gate.set()
        for _ in range(100):
            if not scheduler.snapshot()["fleet"]["in_flight"]: break
            time.sleep(.005)
        scheduler.refresh("fleet"); scheduler.tick()
        self.assertEqual(len(calls), 1)
        self.assertTrue(scheduler.snapshot()["fleet"]["stale"])
        self.assertEqual(scheduler.snapshot()["fleet"]["retry_at"], 2800)
        scheduler.close()

    def test_actual_cli_clone_refresh_and_explicit_git_credential_helper(self):
        """Real audit engine/Git, offline remotes; fake gh cannot write or use fallback."""
        real_git = shutil.which("git")
        def git(directory, *args):
            return subprocess.run([real_git, "-C", str(directory), *args], check=True,
                                  capture_output=True, text=True, env={"PATH": os.environ["PATH"], "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}).stdout
        for name in ("sync/apply-overrides.sh", "lib/manifest-fact-helpers.sh", "lib/template-substitution.sh", "lib/sync-audit-json.sh"):
            target = self.hub / "scripts" / name; target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / "scripts" / name, target)
        shutil.copyfile(ROOT / "scripts/sync-to-downstream.sh", self.script)
        # Explicit GH_TOKEN makes the real startup helper skip operator preflight.
        (self.hub / "scripts/lib/preflight-helpers.sh").write_text('auto_source_preflight() { [ -n "${GH_TOKEN:-}" ] || { touch "' + str(self.directory / "forbidden-preflight") + '"; return 1; }; }\n')
        (self.hub / "canonical.txt").write_text("same\n")
        (self.hub / ".mergepath-sync.yml").write_text('version: 1\nconsumers:\n  - {name: one, repo: fixture/one, visibility: public}\n  - {name: two, repo: fixture/two, visibility: private}\npaths:\n  - {path: canonical.txt, type: canonical, consumers: all}\n')
        subprocess.run([real_git, "init", "-qb", "main", str(self.hub)], check=True, capture_output=True)
        git(self.hub, "add", "-A")
        git(self.hub, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
        sources = {}
        for name in ("one", "two"):
            source = self.directory / ("remote-" + name)
            subprocess.run([real_git, "clone", "-q", str(self.hub), str(source)], check=True, capture_output=True)
            sources["fixture/" + name] = str(source)
        bindir = self.directory / "tools"; bindir.mkdir()
        calls = self.directory / "calls.jsonl"; denied = self.directory / "denied"
        prelude = ('#!' + sys.executable + '\nimport os,sys,json,subprocess\n'
                   'a=sys.argv[1:]\nassert os.environ.get("GH_TOKEN")=="review-fixture"\n'
                   'assert not any(k.startswith("OP_PREFLIGHT") or k in ("GITHUB_TOKEN","SSH_AUTH_SOCK","HTTPS_PROXY") for k in os.environ)\n'
                   'with open(' + repr(str(calls)) + ',"a") as f:f.write(json.dumps({"tool":os.path.basename(sys.argv[0]),"args":a,"reviewer":True})+"\\n")\n')
        gh = bindir / "gh"
        gh.write_text(prelude + 'sources=' + repr(sources) + '\nreal_git=' + repr(real_git) + '\n'
            'if a[:2]==["auth","git-credential"]:\n'
            ' data=sys.stdin.read();assert "protocol=https" in data and "host=github.com" in data\n'
            ' print("username=fixture\\npassword="+os.environ["GH_TOKEN"]);sys.exit(0)\n'
            'if os.path.exists(' + repr(str(denied)) + '):sys.exit(1)\n'
            'if a[:2]==["repo","clone"]:\n'
            ' assert a[2] in sources\n'
            ' subprocess.run([real_git,"-c","protocol.file.allow=always","clone","-q",sources[a[2]],a[3]],check=True)\n'
            ' subprocess.run([real_git,"-C",a[3],"remote","set-url","origin","https://github.com/"+a[2]+".git"],check=True);sys.exit(0)\n'
            'if a[:2]==["api","graphql"]:\n'
            ' print(json.dumps({"data":{"repository":{"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":False,"endCursor":None}}}}}));sys.exit(0)\n'
            'sys.exit(99)\n')
        gitshim = bindir / "git"
        gitshim.write_text(prelude + 'real_git=' + repr(real_git) + '\nsources=' + repr(sources) + '\n'
            'if "push" in a:sys.exit(99)\n'
            'if len(a)>2 and a[0]=="-C" and a[2] in ("ls-remote","fetch"):\n'
            ' root=a[1];remote=subprocess.check_output([real_git,"-C",root,"remote","get-url","origin"],text=True).strip()\n'
            ' key=remote.removeprefix("https://github.com/").removesuffix(".git");assert key in sources\n'
            ' if a[2]=="ls-remote":a=["-c","protocol.file.allow=always","ls-remote","--symref",sources[key],"HEAD"]\n'
            ' else:a=["-c","protocol.file.allow=always","-C",root,"fetch","--depth=1","--quiet",sources[key],a[-1]]\n'
            'sys.exit(subprocess.call([real_git,*a]))\n')
        gh.chmod(0o700); gitshim.chmod(0o700)
        provider = self.provider(utilities={"bash": shutil.which("bash"), "git": str(gitshim), "gh": str(gh)})
        with patch.dict(os.environ, {"GH_TOKEN": "author", "OP_PREFLIGHT_AUTHOR_PAT": "author", "GITHUB_TOKEN": "keyring", "HTTPS_PROXY": "forbidden"}):
            first = provider.fetch(time.monotonic() + 15).data
            second = provider.fetch(time.monotonic() + 15).data
        self.assertTrue(first["complete"] and second["complete"])
        self.assertFalse((self.directory / "forbidden-preflight").exists())
        entries = [json.loads(line) for line in calls.read_text().splitlines()]
        self.assertEqual(sum(e["args"][:2] == ["repo", "clone"] for e in entries), 2)
        self.assertTrue(any("ls-remote" in e["args"] for e in entries))
        self.assertTrue(any("fetch" in e["args"] for e in entries))
        self.assertTrue(all(e["reviewer"] for e in entries))
        env = provider._environment()
        credential = subprocess.run([real_git, "credential", "fill"], input="protocol=https\nhost=github.com\npath=fixture/one.git\n\n", env=env, text=True, capture_output=True, timeout=3)
        self.assertEqual(credential.returncode, 0)
        self.assertIn("password=review-fixture", credential.stdout)
        denied.touch()
        failed = provider.fetch(time.monotonic() + 15).data
        self.assertFalse(failed["complete"])
        self.assertTrue(all(e["status"] == "fetch-error" and e["record"] is not None for e in failed["repositories"]))


def shlex_quote(value):
    import shlex
    return shlex.quote(value)


if __name__ == "__main__":
    unittest.main()
