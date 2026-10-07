"""Hermetic fast-source, canonical status, resource bounds and join regressions."""
import importlib
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
from types import SimpleNamespace
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
L = importlib.import_module("mergepath.cockpit.live_agents")
from mergepath.cockpit.inventory import Repository
from mergepath.cockpit.github import ClientError

ROOT = Path(__file__).resolve().parents[1]
NOW = 1800000000


def record(**changes):
    value = dict(schema="p4b-heartbeat/v1", run_id="p4b-" + "a" * 32, repo="owner/hub", pr="1",
                 pid=123, process_started_at="  Fri Oct  2 00:00:00 2026", head="a" * 40,
                 reviewer="nathanpayne-codex", direction="claude->codex", stage="adapter", dry_run=False,
                 stages=[{"stage": "barrier"}, {"stage": "adapter"}], started_at_epoch=NOW - 1000,
                 stage_at_epoch=NOW - 900, adapter_started_at_epoch=NOW - 900,
                 adapter_elapsed_seconds=None, adapter_timeout_seconds=1000, adapter_exit_code=None,
                 exit_code=None, adapter_verdict=None, summary_emitted=False, verdict=None,
                 token_count=None, findings_count=None, review_posted=False, review_acknowledgment=None,
                 checkout="/private/machine/path")
    value.update(changes)
    return value


class LiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name).resolve()
        self.calls = []
        def status(value, deadline):
            self.calls.append(value["run_id"])
            return "running"
        self.provider = L.LiveAgentsProvider([Repository("hub", "owner/hub", True), Repository("other", "owner/other")], self.path, ROOT, status=status, clock=lambda: NOW)

    def tearDown(self):
        self.temp.cleanup()

    def write(self, value=None, filename=None):
        value = value or record()
        path = self.path / (filename or value["run_id"] + ".json")
        path.write_text(json.dumps(value))
        return path

    def fetch(self):
        return self.provider.fetch(time.monotonic() + 5).data

    def test_global_once_enrolled_only_scrubbed(self):
        self.write()
        self.write(record(repo="owner/foreign", run_id="p4b-foreign"))
        with patch.object(L.os, "scandir", wraps=os.scandir) as scan:
            data = self.fetch()
        self.assertEqual(scan.call_count, 1)
        self.assertEqual(self.calls, [record()["run_id"]])
        self.assertEqual(len(data["live"]), 1)
        self.assertNotIn("/private", json.dumps(data))
        self.assertNotIn("process_started_at", data["live"][0])
        self.assertTrue(data["coverage_complete"])

    def test_old_publication_is_running_from_fresh_probe(self):
        self.write(record(stage_at_epoch=1, started_at_epoch=1, adapter_started_at_epoch=2))
        row = self.fetch()["live"][0]
        self.assertEqual(row["process_status"], "running")
        self.assertEqual(row["observed_at"], NOW)

    def test_empty_is_observed_missing_directory_fails(self):
        self.assertTrue(self.fetch()["hasObservations"])
        self.provider.directory = self.path / "missing"
        with self.assertRaises(ClientError):
            self.fetch()

    def test_malformed_only_cannot_establish_empty(self):
        self.write(filename="p4b-wrong.json")
        data = self.fetch()
        self.assertFalse(data["hasObservations"])
        self.assertFalse(data["coverage_complete"])
        self.assertEqual(data["live"], [])

    def test_invalid_foreign_is_not_silently_valid_coverage(self):
        self.write(record(repo="owner/foreign", schema="other"))
        self.assertFalse(self.fetch()["coverage_complete"])

    def test_numeric_overflow_and_scalar_adapter_are_isolated_per_record(self):
        self.write(record(run_id="p4b-valid-companion"))
        for changes in ({"pid": 10 ** 500}, {"adapter": 42}):
            with self.subTest(changes=list(changes)):
                self.calls.clear()
                self.write(record(run_id="p4b-malformed", **changes))
                data = self.fetch()
                self.assertEqual([row["run_id"] for row in data["live"]], ["p4b-valid-companion"])
                self.assertEqual(self.calls, ["p4b-valid-companion"])
                self.assertTrue(data["hasObservations"])
                self.assertFalse(data["coverage_complete"])
                self.assertEqual(data["diagnostics"], ["A heartbeat record was malformed or refused; coverage is incomplete."])
                self.assertNotIn("42", json.dumps(data["diagnostics"]))

    def test_symlink_fifo_oversize_refused(self):
        target = self.path / "unrelated"
        target.write_text(json.dumps(record()))
        (self.path / "p4b-symlink.json").symlink_to(target)
        os.mkfifo(self.path / "p4b-fifo.json")
        (self.path / "p4b-large.json").write_bytes(b"x" * (L.MAX_RECORD_BYTES + 1))
        self.assertFalse(self.fetch()["coverage_complete"])
        self.assertEqual(self.calls, [])

    def test_directory_components_no_follow(self):
        link = self.path / "link"
        link.symlink_to(self.path, target_is_directory=True)
        self.provider.directory = link
        with self.assertRaises(ClientError):
            self.fetch()

    def test_record_and_scan_limits(self):
        for i in range(4):
            self.write(record(run_id=f"p4b-{i}"))
        with patch.object(L, "MAX_RECORDS", 2):
            data = self.fetch()
        self.assertEqual(len(data["live"]), 2)
        self.assertFalse(data["coverage_complete"])
        with patch.object(L, "MAX_SCAN", 1):
            self.assertFalse(self.fetch()["coverage_complete"])

    def test_terminal_retention_cannot_hide_later_live_record_within_scan(self):
        for index in range(70):
            self.write(record(run_id=f"p4b-terminal-{index:03d}", stage="done", stages=[{"stage": "barrier"}, {"stage": "done"}], stage_at_epoch=NOW - index))
        self.write(record(run_id="p4b-running"))
        actual = os.scandir
        def ordered(fd):
            with actual(fd) as entries:
                values = sorted(entries, key=lambda entry: (entry.name == "p4b-running.json", entry.name))
            return contextlib.nullcontext(values)
        with patch.object(L.os, "scandir", ordered):
            data = self.fetch()
        self.assertEqual([row["run_id"] for row in data["live"]], ["p4b-running"])
        self.assertEqual(self.calls, ["p4b-running"])
        self.assertEqual(len(data["live"]) + len(data["terminal"]), 64)
        self.assertEqual({row["run_id"] for row in data["terminal"]}, {f"p4b-terminal-{i:03d}" for i in range(63)})
        self.assertFalse(data["coverage_complete"])
        self.assertTrue(data["hasObservations"])
        self.assertLessEqual(len(self.provider._elapsed), 64)

    def test_selection_is_deterministic_before_probes_with_total_record_cap(self):
        for index in range(70):
            self.write(record(run_id=f"p4b-live-{index:03d}"))
        self.write(record(run_id="p4b-terminal", stage="done", stages=[{"stage": "barrier"}, {"stage": "done"}]))
        actual = os.scandir
        def reversed_entries(fd):
            with actual(fd) as entries:
                values = sorted(entries, key=lambda entry: entry.name, reverse=True)
            return contextlib.nullcontext(values)
        with patch.object(L.os, "scandir", reversed_entries):
            data = self.fetch()
        self.assertEqual([row["run_id"] for row in data["live"]], [f"p4b-live-{i:03d}" for i in range(64)])
        self.assertEqual(data["terminal"], [])
        self.assertEqual(self.calls, [f"p4b-live-{i:03d}" for i in range(4)])
        self.assertEqual(sum(row["process_status"] == "unknown" for row in data["live"]), 60)
        self.assertFalse(data["coverage_complete"])
        self.assertLessEqual(len(self.provider._elapsed), 64)

    def test_terminal_selection_newest_stage_then_id_with_no_process_probes(self):
        for index in range(66):
            self.write(record(run_id=f"p4b-terminal-{index:03d}", stage="done", stages=[{"stage": "barrier"}, {"stage": "done"}], stage_at_epoch=NOW - min(index, 63)))
        data = self.fetch()
        self.assertEqual({row["run_id"] for row in data["terminal"]}, {f"p4b-terminal-{i:03d}" for i in range(64)})
        self.assertEqual(data["live"], [])
        self.assertEqual(self.calls, [])
        self.assertFalse(data["coverage_complete"])

    def test_live_selection_does_not_claim_records_beyond_scan_limit(self):
        for index in range(512):
            self.write(record(run_id=f"p4b-terminal-{index:03d}", stage="done", stages=[{"stage": "barrier"}, {"stage": "done"}]))
        self.write(record(run_id="p4b-unscanned-live"))
        actual = os.scandir
        def ordered(fd):
            with actual(fd) as entries:
                values = sorted(entries, key=lambda entry: entry.name)
            return contextlib.nullcontext(values)
        with patch.object(L.os, "scandir", ordered):
            data = self.fetch()
        self.assertEqual(data["live"], [])
        self.assertEqual(len(data["terminal"]), 64)
        self.assertEqual(self.calls, [])
        self.assertFalse(data["coverage_complete"])
        self.assertIn("Heartbeat directory scan limit reached.", data["diagnostics"])
        self.assertLessEqual(len(self.provider._elapsed), 64)

    def test_probe_limit_keeps_unprobed_rows_unknown_incomplete(self):
        for i in range(6):
            self.write(record(run_id=f"p4b-{i}"))
        data = self.fetch()
        self.assertEqual(len(self.calls), L.MAX_PROBES)
        self.assertEqual(sum(row["process_status"] == "unknown" for row in data["live"]), 2)
        self.assertFalse(data["coverage_complete"])
        self.assertTrue(data["hasObservations"])

    def test_deadline_cannot_publish_late_fresh_sample(self):
        self.write()
        with self.assertRaises(ClientError):
            self.provider.fetch(time.monotonic() - 1)
        def late(value, deadline):
            time.sleep(.025)
            return "crashed"
        self.provider.status = late
        with self.assertRaises(ClientError):
            self.provider.fetch(time.monotonic() + .01)

    def test_status_indeterminate_is_unknown_not_crash(self):
        self.write()
        self.provider.status = lambda value, deadline: "refused"
        row = self.fetch()["live"][0]
        self.assertEqual(row["process_status"], "unknown")
        self.assertIsNone(row["adapter_elapsed_observed_seconds"])

    def test_unknown_and_crash_retain_only_compatible_last_verified_elapsed(self):
        self.write()
        first = self.fetch()["live"][0]
        self.assertEqual(first["adapter_elapsed_observed_seconds"], 900)
        self.provider.clock = lambda: NOW + 100
        self.provider.status = lambda value, deadline: "unknown"
        unknown = self.fetch()["live"][0]
        self.assertEqual(unknown["adapter_elapsed_observed_seconds"], 900)
        self.assertEqual(unknown["adapter_elapsed_observed_at"], NOW)
        self.provider.status = lambda value, deadline: "crashed"
        self.assertEqual(self.fetch()["live"][0]["adapter_elapsed_observed_seconds"], 900)
        self.write(record(process_started_at="different process instance"))
        self.assertIsNone(self.fetch()["live"][0]["adapter_elapsed_observed_seconds"])

    def test_terminal_summary_and_post_are_distinct(self):
        self.write(record(stage="done", stages=[{"stage": "barrier"}, {"stage": "adapter"}, {"stage": "done"}], adapter_verdict="APPROVED", verdict="APPROVED", token_count=100))
        data = self.fetch()
        self.assertEqual(data["live"], [])
        self.assertIsNone(data["terminal"][0]["verdict"])
        self.assertIsNone(data["terminal"][0]["posted_outcome"])
        self.write(record(stage="done", stages=[{"stage": "barrier"}, {"stage": "adapter"}, {"stage": "posting"}, {"stage": "done"}], summary_emitted=True, verdict="APPROVED", review_posted=True, review_acknowledgment="failed", exit_code=7))
        row = self.fetch()["terminal"][0]
        self.assertEqual(row["posted_outcome"], "APPROVED")
        self.assertEqual(row["exit_code"], 7)
        self.assertEqual(row["review_acknowledgment"], "failed")

    def test_invalid_timing_and_pid(self):
        self.write(record(adapter_started_at_epoch=NOW + 1, adapter_timeout_seconds=0))
        row = self.fetch()["live"][0]
        self.assertIsNone(row["adapter_started_at_epoch"])
        self.assertIsNone(row["adapter_timeout_seconds"])
        self.write(record(pid=True))
        self.assertFalse(self.fetch()["coverage_complete"])

    def test_join_preserves_history_and_totals_no_new_rows(self):
        terminal = L.normalize(record(stage="done", stages=[{"stage": "barrier"}, {"stage": "done"}], summary_emitted=True, verdict="CHANGES_REQUESTED", review_posted=True), record()["run_id"] + ".json", NOW)
        terminal["observed_at"] = NOW
        original = {"repo": "owner/hub", "run_id": terminal["run_id"], "pr": "1", "head_sha": "a" * 40, "reviewer": "nathanpayne-codex", "started_at_epoch": NOW - 1000, "verdict": "CHANGES_REQUESTED", "tokens": {"total": 100}, "cost": {"usd": 1}}
        result = L.join_history([terminal], [original])
        self.assertTrue(result["history"][0]["heartbeat"]["compatible"])
        self.assertEqual(result["history"][0]["tokens"], original["tokens"])
        self.assertNotIn("heartbeat", original)
        terminal["head"] = "b" * 40
        self.assertTrue(L.join_history([terminal], [original])["diagnostics"])
        self.assertEqual(L.join_history([terminal], [])["history"], [])
        self.assertEqual(L.join_history([terminal], [])["unmatched"], [terminal["id"]])


class CanonicalTests(unittest.TestCase):
    def test_real_helper_with_stub_ps_preserves_exact_start_and_rc_semantics(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            ps = path / "ps"
            probe = L.CanonicalStatus(ROOT)
            for body, expected in [("printf '  Fri Oct  2 00:00:00 2026\\n'", "running"),
                                   ("printf 'Fri Oct  2 00:00:00 2026\\n'", "crashed"),
                                   ("exit 1", "crashed"), ("exit 2", "unknown"),
                                   ("printf denied; exit 1", "unknown"), ("exit 0", "unknown")]:
                ps.write_text("#!/bin/sh\n" + body + "\n")
                ps.chmod(0o700)
                with patch.object(L.os, "defpath", str(path) + ":" + os.defpath):
                    # A UTC-marked start time (the current writer) must match ps exactly.
                    self.assertEqual(probe(record(process_started_at="  Fri Oct  2 00:00:00 2026 UTC"), time.monotonic() + 2), expected)
            self.assertEqual(probe(record(process_started_at=None), time.monotonic() + 2), "unknown")
            # An unmarked record from before the UTC pin matches by whole zone offset (#1837 review).
            for stored, expected in [("Fri Oct  2 14:00:00 2026", "running"), ("Thu Oct  1 13:30:00 2026", "running"),
                                     ("Fri Oct  2 00:00:07 2026", "crashed"), ("not a start time", "unknown")]:
                ps.write_text("#!/bin/sh\nprintf '  Fri Oct  2 00:00:00 2026\\n'\n")
                ps.chmod(0o700)
                with patch.object(L.os, "defpath", str(path) + ":" + os.defpath):
                    self.assertEqual(probe(record(process_started_at=stored), time.monotonic() + 2), expected, stored)

    def test_real_helper_and_ps_match_a_heartbeat_written_under_a_non_utc_zone(self):
        # #1830: lstart follows the caller zone. The orchestrator may run with
        # TZ set while the probe scrubs its environment; both must agree.
        with tempfile.TemporaryDirectory() as directory:
            run_id = "p4b-" + "b" * 32
            writer = subprocess.Popen(
                ["bash", "-c", 'source "$1"; p4b_heartbeat_start; printf "ready\\n"; exec sleep 30',
                 "tz-writer", str(ROOT / "scripts/phase-4b/heartbeat.sh")],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                env={"PATH": os.environ.get("PATH", os.defpath), "LC_ALL": "C", "TZ": "Pacific/Kiritimati",
                     "P4B_HEARTBEAT_DIR": directory, "P4B_ACCT_RUN_ID": run_id})
            try:
                self.assertEqual(writer.stdout.readline(), b"ready\n")
                written = json.loads((Path(directory) / (run_id + ".json")).read_text(encoding="utf-8"))
                self.assertEqual(written["pid"], writer.pid)
                self.assertTrue(written["process_started_at"])
                self.assertEqual(L.CanonicalStatus(ROOT)(written, time.monotonic() + 2), "running")
            finally:
                writer.kill()
                writer.wait()
                writer.stdout.close()

    def test_probe_timeout_and_output_bound_fail_unknown(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            helper = root / "scripts/phase-4b/heartbeat.sh"
            helper.parent.mkdir(parents=True)
            helper.write_text("p4b_heartbeat_status(){ sleep 10; }\n")
            start = time.monotonic()
            self.assertEqual(L.CanonicalStatus(root)(record(), start + .3), "unknown")
            self.assertLess(time.monotonic() - start, .5)
            helper.write_text("p4b_heartbeat_status(){ printf '%05000d' 1; }\n")
            self.assertEqual(L.CanonicalStatus(root)(record(), time.monotonic() + 1), "unknown")


class StartupDirectoryTests(unittest.TestCase):
    def launch(self, environment, opened):
        main = importlib.import_module("mergepath.cockpit.__main__")
        captured, closed = [], []
        scheduler = SimpleNamespace(register=lambda *args, **kwargs: None, start=lambda: None, close=lambda: None)
        app = SimpleNamespace(scheduler=scheduler, register_panel=lambda *args: None,
                              launch_url=lambda port: "http://127.0.0.1:1/fixture",
                              publish=lambda: None, stopping=SimpleNamespace(set=lambda: None),
                              close=lambda: closed.append(True))
        server = SimpleNamespace(server_address=("127.0.0.1", 1), serve_forever=lambda: None,
                                 shutdown=lambda: None, server_close=lambda: None)
        thread = SimpleNamespace(start=lambda: None, is_alive=lambda: False, join=lambda **kwargs: None)
        empty = SimpleNamespace(fetch=lambda deadline: None, close=lambda: None)

        def live(inventory, directory, trusted_root):
            provider = L.LiveAgentsProvider(inventory, directory, trusted_root, clock=lambda: NOW)
            captured.append(provider)
            return provider

        output = io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.dict(os.environ, environment, clear=True))
            stack.enter_context(patch.object(main.GitHubClient, "from_environment",
                                            return_value=SimpleNamespace(_token="fixture-only")))
            stack.enter_context(patch.object(main, "load_inventory", return_value=(Repository("hub", "owner/hub", True),)))
            stack.enter_context(patch.object(main, "resolve_history_settings", return_value=((), {})))
            stack.enter_context(patch.object(main, "load_reviewers", return_value=("fixture-reviewer",)))
            stack.enter_context(patch.object(main, "Application", return_value=app))
            for name in ("CIProvider", "PRProvider", "FleetProvider", "ActionsProvider", "AgentsProvider", "SyncProvider", "AuthorBudgetProvider"):
                stack.enter_context(patch.object(main, name, return_value=empty))
            factory = stack.enter_context(patch.object(main, "LiveAgentsProvider", side_effect=live))
            http = stack.enter_context(patch.object(main, "CockpitServer", return_value=server))
            stack.enter_context(patch.object(main.threading, "Thread", return_value=thread))
            opener = stack.enter_context(patch.object(main, "open_browser", side_effect=lambda url: opened(captured)))
            stack.enter_context(contextlib.redirect_stdout(output))
            stack.enter_context(contextlib.redirect_stderr(output))
            result = main.main([])
        return result, captured, closed, output.getvalue(), factory, http, opener

    def test_startup_default_empty_and_absolute_observe_immutable_directory(self):
        for override in (None, "", "custom"):
            with self.subTest(override=override), tempfile.TemporaryDirectory() as temp:
                home = Path(temp).resolve()
                default = home / ".local/state/mergepath/phase-4b-runs"
                custom, other = home / "custom", home / "other"
                for path in (default, custom, other):
                    path.mkdir(parents=True)
                selected = custom if override == "custom" else default
                value = record(stage="done", stages=[{"stage": stage} for stage in L.STAGES])
                (selected / (value["run_id"] + ".json")).write_text(json.dumps(value))
                switched = record(run_id="p4b-different", stage="done", stages=[{"stage": stage} for stage in L.STAGES])
                (other / (switched["run_id"] + ".json")).write_text(json.dumps(switched))
                env = {} if override is None else {"P4B_HEARTBEAT_DIR": str(custom) if override == "custom" else ""}

                def opened(providers):
                    self.assertEqual(len(providers), 1)
                    provider = providers[0]
                    self.assertEqual(provider.directory, selected.resolve())
                    first = provider.fetch(time.monotonic() + 2).data
                    self.assertEqual([row["run_id"] for row in first["terminal"]], [value["run_id"]])
                    self.assertTrue(first["coverage_complete"])
                    os.environ["P4B_HEARTBEAT_DIR"] = str(other)
                    second = provider.fetch(time.monotonic() + 2).data
                    self.assertEqual(second["terminal"], first["terminal"])
                    self.assertEqual(provider.directory, selected.resolve())
                    return True

                with patch.object(Path, "home", return_value=home), patch.object(L.subprocess, "Popen") as process:
                    result, providers, closed, output, factory, http, opener = self.launch(env, opened)
                self.assertEqual(result, 0, output)
                factory.assert_called_once()
                self.assertEqual(factory.call_args.args[1], selected.resolve())
                http.assert_called_once(); opener.assert_called_once()
                self.assertEqual(closed, [True])
                process.assert_not_called()

    def test_startup_refuses_relative_and_oversize_override_before_server(self):
        for value in ("relative/heartbeat", "/" + "a" * 4096):
            with self.subTest(length=len(value)):
                result, providers, closed, output, factory, http, opener = self.launch(
                    {"P4B_HEARTBEAT_DIR": value}, lambda providers: True)
                self.assertEqual(result, 1)
                self.assertEqual(providers, [])
                factory.assert_not_called(); http.assert_not_called(); opener.assert_not_called()
                self.assertEqual(closed, [True])
                self.assertIn("Cockpit cannot start", output)
                self.assertNotIn(value, output)


if __name__ == "__main__":
    unittest.main()
