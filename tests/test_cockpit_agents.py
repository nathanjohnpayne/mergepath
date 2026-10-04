"""Hermetic accounting/local filesystem/real server tests (no remote or credentials)."""
import copy
import http.client
import json
import os
import shutil
import sys
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from pathlib import Path

from mergepath.cockpit.agents import (Accounting, AgentsProvider, Checkout, LocalReader, cost_for,
                                     discover_checkouts, normalize_loop, resolve_history_settings)
from mergepath.cockpit.github import ClientError, GitHubClient
from mergepath.cockpit.inventory import Repository
from mergepath.cockpit.server import Application, CockpitServer, COOKIE

ROOT = Path(__file__).resolve().parents[1]
REPO = "owner/hub"
INVENTORY = (Repository("hub", REPO, True), Repository("consumer", "owner/consumer"))


def loop(run_id="p4b-test-one", provider="codex", total=100, verdict="CHANGES_REQUESTED", started=1790989200):
    return {"loop": 1, "run_id": run_id, "started_at_epoch": started, "reviewer": "nathanpayne-" + provider,
            "adapter": "review-via-" + provider + ".sh", "direction": "other->" + provider, "head_sha": "a" * 40,
            "verdict": verdict, "posted": "posted", "fell_back": False, "elapsed_seconds": 30,
            "tokens": {"total": total, "input": None, "output": None, "cache_creation": None,
                       "cache_read": None, "reasoning": None, "cost_usd": None, "source": "CLI"},
            "findings": dict.fromkeys(("P0", "P1", "P2", "P3", "nitpick", "unknown"), 0),
            "cli_version": None, "timeout_seconds": 900, "effort": "high", "throttle_events": None,
            "plan_auth": None, "fail_closed": {"happened": False, "reason": None, "duration_seconds": None}}


def write_loop(root, value, filename="owner-hub-pr1.jsonl"):
    target = root / ".mergepath/phase-4b-loops" / filename
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("a") as file:
        file.write(json.dumps({"schema": "p4b-loop-log/v1", "loop": value, "started_at_epoch": value.get("started_at_epoch"), "details": []}) + "\n")
    return target


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.a = Path(self.temp.name) / "a"
        self.b = Path(self.temp.name) / "b"
        self.a.mkdir(); self.b.mkdir()

    def provider(self, roots=None, **kwargs):
        return AgentsProvider(INVENTORY, tuple(Checkout(REPO, root) for root in roots or (self.a,)), ROOT, **kwargs)

    def sample(self, **kwargs):
        return self.provider(**kwargs).fetch(time.monotonic() + 20).data

    def test_nonapproval_history_dedup_genuine_id_across_roots_and_archives(self):
        row = loop()
        write_loop(self.a, row)
        write_loop(self.b, row)
        write_loop(self.a, row, "owner-hub-pr1.jsonl.archive")
        unavailable = loop("p4b-refusal", verdict="UNAVAILABLE", total=None)
        unavailable["fail_closed"]["happened"] = True
        write_loop(self.b, unavailable)
        data = self.sample(roots=(self.a, self.b))
        self.assertEqual(len(data["history"]), 2)
        self.assertEqual(data["canonical_totals"]["adapter_invocations"], 2)
        self.assertEqual(data["canonical_totals"]["tokens_total"], 100)
        self.assertEqual(data["canonical_totals"]["fail_closed_events"], 1)
        self.assertEqual(data["coverage"]["tokens_measured"], 1)
        self.assertIn("UNAVAILABLE", [r["verdict"] for r in data["history"]])

    def test_same_run_id_different_repository_is_independent(self):
        write_loop(self.a, loop())
        write_loop(self.a, loop(), "owner-consumer-pr2.jsonl")
        data = self.sample()
        self.assertEqual(len(data["history"]), 2)

    def test_legacy_independent_loops_never_cross_checkout_dedup(self):
        legacy = loop(None)
        write_loop(self.a, legacy); write_loop(self.b, legacy)
        data = self.sample(roots=(self.a, self.b))
        self.assertEqual(len(data["history"]), 2)
        self.assertEqual(data["coverage"]["legacy_runs"], 2)
        self.assertTrue(all(r["identity"] == "legacy_locator" for r in data["history"]))

    def test_canonical_totals_equal_helper_and_per_pr(self):
        rows = [loop(), loop("p4b-claude", provider="claude", total=12)]
        rows[1]["tokens"].update(input=10, output=2, cost_usd=.23)
        for row in rows:
            write_loop(self.a, row)
        data = self.sample()
        expected = Accounting(ROOT).totals([rows], time.monotonic() + 5)[0]
        self.assertEqual(data["canonical_totals"], expected)
        self.assertEqual(data["per_pr"][0]["totals"], expected)
        self.assertIsNone(expected["reported_cost_usd"])

    def test_codex_split_unavailable_and_cost_bounded_without_imputed_split(self):
        row = loop(total=1000000)
        row["tokens"].update(input=800000, output=200000)
        write_loop(self.a, row)
        data = self.sample(price_keys={"codex": "openai.gpt-5.3-codex.standard"})
        actual = data["history"][0]
        self.assertIsNone(actual["tokens"]["input"])
        self.assertIsNone(actual["tokens"]["output"])
        self.assertEqual(actual["cost"]["kind"], "bounded_estimate")
        self.assertEqual(actual["cost"]["low_usd"], .175)
        self.assertEqual(actual["cost"]["high_usd"], 14)
        self.assertIsNone(actual["cost"]["usd"])

    def test_reported_cost_and_estimate_provenance(self):
        row = loop("p4b-claude", "claude", 1000)
        row["tokens"].update(input=900, output=100, cache_read=2000, cache_creation=0)
        write_loop(self.a, row)
        data = self.sample(price_keys={"claude": "anthropic.claude-sonnet-4.6.standard"})
        self.assertEqual(data["history"][0]["cost"]["kind"], "estimated")
        self.assertAlmostEqual(data["history"][0]["cost"]["usd"], .0048)
        self.assertEqual(data["history"][0]["cost"]["price_version"], "2026-07-01")
        self.assertEqual(self.sample()["history"][0]["cost"]["kind"], "unavailable")
        row["tokens"]["cost_usd"] = .09
        cost = cost_for(normalize_loop(row), {}, {})
        self.assertEqual(cost["kind"], "reported")
        self.assertEqual(cost["usd"], .09)

    def test_conflicts_unavailable_and_compatible_post_lifecycle(self):
        row = loop(); row["posted"] = "not-posted"
        write_loop(self.a, row)
        row["posted"] = "posted"; write_loop(self.b, row)
        good = self.sample(roots=(self.a, self.b))
        self.assertFalse(good["history"][0]["conflict"])
        self.assertEqual(good["history"][0]["posted"], "posted")
        row["verdict"] = "APPROVED"; write_loop(self.b, row)
        bad = self.sample(roots=(self.a, self.b))
        self.assertTrue(bad["history"][0]["conflict"])
        self.assertFalse(bad["history_complete"])
        self.assertIsNone(bad["canonical_totals"]["tokens_total"])

    def test_approval_is_crosscheck_no_second_spend_and_mismatch_visible(self):
        row = loop()
        write_loop(self.a, row)
        totals = Accounting(ROOT).totals([[row]], time.monotonic() + 5)[0]
        record = {"schema": "p4b-accounting/v1", "pr": 1, "loops": [row], "totals": totals}
        ledger = self.a / ".mergepath/phase-4b-ledger.jsonl"
        ledger.write_text(json.dumps(record) + "\n")
        data = self.sample()
        self.assertEqual(data["canonical_totals"]["adapter_invocations"], 1)
        self.assertEqual(data["diagnostics"], [])
        record["totals"]["tokens_total"] = 999
        ledger.write_text(json.dumps(record) + "\n")
        self.assertIn("disagrees", self.sample()["diagnostics"][0])

    def test_malformed_local_ledger_line_is_atomic_and_helper_gets_valid_groups(self):
        healthy = loop("p4b-companion")
        write_loop(self.a, healthy)
        totals = Accounting(ROOT).totals([[healthy]], time.monotonic() + 5)[0]
        good = {"schema": "p4b-accounting/v1", "pr": 1, "loops": [healthy], "totals": totals}
        for invalid in (None, {}, {"tokens": []}):
            with self.subTest(invalid=invalid):
                rejected = {**good, "loops": [loop("p4b-rejected-prefix"), invalid]}
                (self.a / ".mergepath/phase-4b-ledger.jsonl").write_text(json.dumps(rejected) + "\n" + json.dumps(good) + "\n")
                provider = self.provider()
                with patch.object(provider.accounting, "totals", wraps=provider.accounting.totals) as helper:
                    data = provider.fetch(time.monotonic() + 20).data
                self.assertEqual([row["run_id"] for row in data["history"]], [healthy["run_id"]])
                self.assertEqual(data["canonical_totals"]["adapter_invocations"], 1)
                self.assertEqual(data["canonical_totals"]["tokens_total"], 100)
                self.assertFalse(data["history_complete"])
                groups = helper.call_args.args[0]
                self.assertEqual(len(groups), 3)  # history, valid approval, per-PR
                self.assertEqual(groups[1], [healthy])
                self.assertTrue(all(isinstance(row, dict) and row.get("run_id") == healthy["run_id"] for group in groups for row in group))

    def test_local_ledger_capacity_refuses_whole_line_not_prefix(self):
        healthy = loop("p4b-companion")
        state = self.a / ".mergepath"
        state.mkdir()
        totals = Accounting(ROOT).totals([[healthy]], time.monotonic() + 5)[0]
        good = {"schema": "p4b-accounting/v1", "pr": 1, "loops": [healthy], "totals": totals}
        too_many = {**good, "loops": [loop("p4b-prefix"), loop("p4b-over-limit")]}
        (state / "phase-4b-ledger.jsonl").write_text(json.dumps(good) + "\n" + json.dumps(too_many) + "\n")
        with patch("mergepath.cockpit.agents.MAX_ROWS", 2):
            data = self.sample()
        self.assertEqual([row["run_id"] for row in data["history"]], [healthy["run_id"]])
        self.assertEqual(data["canonical_totals"]["adapter_invocations"], 1)
        self.assertFalse(data["history_complete"])

    def test_history_noise_does_not_consume_eligible_file_limit(self):
        write_loop(self.a, loop())
        directory = self.a / ".mergepath/phase-4b-loops"
        for index in range(513):
            (directory / f"noise-{index}").touch()
        data = self.sample()
        self.assertEqual(len(data["history"]), 1)
        self.assertTrue(data["history_complete"])

    def test_history_eligible_truncation_retains_bounded_subset_and_global_budget(self):
        for index in range(514):
            write_loop(self.a, loop(f"p4b-{index:04d}"), f"owner-hub-pr1-{index:04d}.jsonl.archive")
        write_loop(self.b, loop("p4b-other-root"))
        reads = []
        actual = LocalReader.read
        def read(reader, fd, name):
            reads.append(name)
            return actual(reader, fd, name)
        with patch.object(LocalReader, "read", read):
            data = self.sample(roots=(self.a, self.b))
        self.assertEqual(len(reads), 512)
        self.assertEqual(reads[-1], "prices.json")
        self.assertEqual(len(data["history"]), 510)
        self.assertEqual({row["run_id"] for row in data["history"]}, {f"p4b-{i:04d}" for i in range(510)})
        self.assertTrue(data["hasObservations"])
        self.assertFalse(data["history_complete"])
        self.assertEqual(data["observed_checkouts"], 1)
        self.assertIn("History file limit reached; coverage is incomplete.", data["diagnostics"])

    def test_legacy_approval_matches_log_occurrences_only_within_checkout(self):
        row = loop(None)
        write_loop(self.a, row); write_loop(self.a, row)
        totals = Accounting(ROOT).totals([[row, row]], time.monotonic() + 5)[0]
        (self.a / ".mergepath/phase-4b-ledger.jsonl").write_text(json.dumps({"schema": "p4b-accounting/v1", "pr": 1, "loops": [row, row], "totals": totals}) + "\n")
        self.assertEqual(len(self.sample()["history"]), 2)

    def test_symlink_fifo_oversize_bad_json_private_paths_never_published(self):
        write_loop(self.a, loop())
        logdir = self.a / ".mergepath/phase-4b-loops"
        outside = Path(self.temp.name) / "secret"
        outside.write_text("private-token-content")
        (logdir / "linked.jsonl").symlink_to(outside)
        os.mkfifo(logdir / "pipe.jsonl")
        (logdir / "large.jsonl").write_bytes(b"x" * (2 * 1024 * 1024 + 1))
        (logdir / "broken.jsonl").write_text("{bad\n")
        data = self.sample()
        encoded = json.dumps(data)
        self.assertNotIn(str(self.temp.name), encoded)
        self.assertNotIn("private-token-content", encoded)
        self.assertFalse(data["history_complete"])
        self.assertEqual(len(data["history"]), 1)

    def test_symlink_parent_refused_missing_checkout_and_deadline(self):
        write_loop(self.b, loop())
        (self.a / ".mergepath").symlink_to(self.b / ".mergepath")
        refused = self.sample()
        self.assertFalse(refused["history_complete"])
        self.assertFalse(refused["hasObservations"])
        self.assertEqual(refused["observed_checkouts"], 0)
        partial = self.sample(roots=(self.a, self.b))
        self.assertTrue(partial["hasObservations"])
        self.assertFalse(partial["history_complete"])
        self.assertEqual(partial["observed_checkouts"], 1)
        self.assertEqual(len(partial["history"]), 1)
        with self.assertRaises(ClientError):
            self.provider().fetch(time.monotonic() - 1)

    def test_bad_numeric_run_identity_repository_and_split_only(self):
        for field, value in (("run_id", {}), ("elapsed_seconds", True), ("elapsed_seconds", float("nan"))):
            row = loop(); row[field] = value
            with self.assertRaises(ValueError):
                normalize_loop(row)
        row = loop("p4b-split", "claude", None); row["tokens"].update(input=10, output=2)
        self.assertEqual(normalize_loop(row)["tokens"]["total"], 12)
        write_loop(self.a, row, "outsider-pr1.jsonl")
        self.assertEqual(self.sample()["history"], [])

    def test_discovery_uses_git_and_scrubs_ambient_credentials(self):
        calls = []
        def run(args, **kwargs):
            calls.append((args, kwargs))
            return subprocess.CompletedProcess(args, 0, f"worktree {self.a}\nHEAD abc\n\nworktree {self.b}\nHEAD def\n", "")
        discovered = discover_checkouts(self.a, REPO, run=run)
        self.assertEqual([item.path for item in discovered], [self.a, self.b])
        self.assertNotIn("GH_TOKEN", calls[0][1]["env"])
        self.assertLessEqual(calls[0][1]["timeout"], 5)

    def test_orphan_ledger_target_unavailable_and_consumer_log_establishes_target(self):
        row = loop()
        totals = Accounting(ROOT).totals([[row]], time.monotonic() + 5)[0]
        (self.a / ".mergepath").mkdir()
        ledger = self.a / ".mergepath/phase-4b-ledger.jsonl"
        ledger.write_text(json.dumps({"schema": "p4b-accounting/v1", "pr": 2, "loops": [row], "totals": totals}) + "\n")
        orphan = self.sample()
        self.assertIsNone(orphan["history"][0]["repo"])
        self.assertEqual(orphan["coverage"]["unattributed_runs"], 1)
        self.assertEqual(orphan["canonical_totals"]["tokens_total"], 100)
        write_loop(self.b, row, "owner-consumer-pr2.jsonl")
        known = self.sample(roots=(self.a, self.b))
        self.assertEqual(len(known["history"]), 1)
        self.assertEqual(known["history"][0]["repo"], "owner/consumer")
        self.assertEqual(known["coverage"]["unattributed_runs"], 0)

    def test_legacy_local_attribution_requires_matching_pr_and_target_evidence(self):
        row = loop(None)
        write_loop(self.a, row, "owner-consumer-pr2.jsonl")
        totals = Accounting(ROOT).totals([[row]], time.monotonic() + 5)[0]
        ledger = self.a / ".mergepath/phase-4b-ledger.jsonl"
        record = {"schema": "p4b-accounting/v1", "pr": 2, "loops": [row], "totals": totals}
        ledger.write_text(json.dumps(record) + "\n")
        self.assertEqual(self.sample()["history"][0]["repo"], "owner/consumer")
        record["pr"] = 1
        ledger.write_text(json.dumps(record) + "\n")
        data = self.sample()
        self.assertEqual(len(data["history"]), 2)
        self.assertEqual(data["coverage"]["unattributed_runs"], 1)

    def test_empty_successful_scan_vs_missing_configured_checkout(self):
        empty = self.sample()
        self.assertTrue(empty["hasObservations"])
        self.assertTrue(empty["history_complete"])
        self.assertEqual(empty["observed_checkouts"], 1)
        self.assertEqual(empty["history"], [])
        missing = self.sample(roots=(self.a / "missing",))
        self.assertFalse(missing["hasObservations"])
        self.assertFalse(missing["history_complete"])

    def test_refused_only_loop_directory_is_not_an_empty_observation(self):
        (self.a / ".mergepath").mkdir()
        (self.a / ".mergepath/phase-4b-loops").symlink_to(self.b)
        refused = self.sample()
        self.assertFalse(refused["hasObservations"])
        self.assertFalse(refused["history_complete"])
        self.assertEqual(refused["observed_checkouts"], 0)
        write_loop(self.b, loop())
        mixed = self.sample(roots=(self.a, self.b))
        self.assertEqual(mixed["observed_checkouts"], 1)
        self.assertEqual(len(mixed["history"]), 1)

    def test_remote_crosscheck_requires_valid_nonempty_accounting_evidence(self):
        write_loop(self.a, loop())
        for entries in (None, [], [{}], [loop(), {}]):
            with self.subTest(entries=entries):
                if entries is None:
                    reviews = []
                else:
                    totals = Accounting(ROOT).totals([entries], time.monotonic() + 5)[0]
                    record = {"schema": "p4b-accounting/v1", "pr": 1, "loops": entries, "totals": totals}
                    reviews = [{"state": "APPROVED", "user": {"login": "nathanpayne-codex"},
                                "body": "<!-- p4b-accounting:v1 " + json.dumps(record) + " -->"}]
                class Client:
                    def pages(self, *args, **kwargs):
                        return reviews
                actual = self.sample(github=Client())
                check = actual["review_crosscheck"]
                self.assertEqual(check["checked_prs"], 0)
                self.assertEqual(check["status"], "partial")
                self.assertTrue(check["diagnostics"])
                self.assertEqual(check["observations"][0]["status"], "unavailable")
                self.assertEqual(check["observations"][0]["error"], "no_evidence" if entries is None else "invalid_response")
                self.assertEqual(actual["canonical_totals"]["tokens_total"], 100)
                self.assertEqual(len(actual["history"]), 1)

    def test_approved_review_crosscheck_paginated_client_cache_and_denial(self):
        row = loop()
        write_loop(self.a, row)
        totals = Accounting(ROOT).totals([[row]], time.monotonic() + 5)[0]
        record = {"schema": "p4b-accounting/v1", "pr": 1, "loops": [row], "totals": totals}
        calls = []
        class Client:
            def pages(self, path, **kwargs):
                calls.append((path, kwargs))
                return [{"state": "APPROVED", "user": {"login": "nathanpayne-codex"},
                         "body": "<!-- p4b-accounting:v1 " + json.dumps(record) + " -->"},
                        {"state": "APPROVED", "user": {"login": "outsider"}, "body": "malicious"}]
        provider = self.provider(github=Client())
        first = provider.fetch(time.monotonic() + 5).data
        self.assertEqual(first["review_crosscheck"]["checked_prs"], 1)
        provider.fetch(time.monotonic() + 5)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][1]["max_pages"], 5)
        class Denied:
            def pages(self, *args, **kwargs):
                raise ClientError("permission_denied")
        denied = self.sample(github=Denied())
        self.assertEqual(len(denied["history"]), 1)
        self.assertEqual(denied["review_crosscheck"]["status"], "partial")
        self.assertIn("permission_denied", denied["review_crosscheck"]["diagnostics"][0])

    def test_real_loopback_authenticated_panel_and_denied_upstream_independent(self):
        write_loop(self.a, loop())
        client = GitHubClient("fixture-token", transport=lambda *a, **k: (_ for _ in ()).throw(AssertionError("no upstream")))
        app = Application(INVENTORY, client)
        self.addCleanup(app.close)
        app.scheduler.register("agents", self.provider().fetch, timeout=20)
        app.register_panel("history", "agents")
        server = CockpitServer(app)
        self.addCleanup(server.server_close)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        self.addCleanup(server.shutdown)
        app.scheduler.tick()
        for _ in range(100):
            if app.scheduler.snapshot()["agents"]["data"] is not None:
                break
            time.sleep(.02)
        port = server.server_address[1]
        def get(cookie=None, host=None):
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
            headers = {"Host": host or f"127.0.0.1:{port}"}
            if cookie: headers["Cookie"] = cookie
            conn.request("GET", app.scope_path + "api/panels/history", headers=headers)
            response = conn.getresponse(); result = response.status, json.loads(response.read()); conn.close()
            return result
        self.assertEqual(get()[0], 401)
        self.assertEqual(get(f"{COOKIE}={app._session}", "foreign.example")[0], 403)
        status, payload = get(f"{COOKIE}={app._session}")
        self.assertEqual(status, 200)
        self.assertEqual(payload["envelope"]["data"]["canonical_totals"]["tokens_total"], 100)
        self.assertNotIn("fixture-token", json.dumps(payload))


class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.hub, self.consumer = self.root / "hub", self.root / "consumer"
        self.hub.mkdir(); self.consumer.mkdir()

    def git_checkout(self, path, worktree):
        env = {"PATH": os.defpath, "HOME": str(self.root), "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
        for args in (["init", "--initial-branch=main"],
                     ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "fixture"],
                     ["worktree", "add", "--detach", str(worktree)]):
            subprocess.run(["git", "-C", str(path), *args], env=env, capture_output=True, check=True, timeout=5)

    def test_default_and_enrolled_consumer_discover_actual_git_worktrees(self):
        hub_tree, consumer_tree = self.root / "hub-tree", self.root / "consumer-tree"
        self.git_checkout(self.hub, hub_tree); self.git_checkout(self.consumer, consumer_tree)
        defaults, prices = resolve_history_settings({}, INVENTORY, self.hub)
        self.assertEqual(set(defaults), {Checkout(REPO, self.hub), Checkout(REPO, hub_tree)})
        self.assertEqual(dict(prices), {})
        with self.assertRaises(TypeError):
            prices["codex"] = "invented"
        combined, _ = resolve_history_settings({"checkouts": {"owner/consumer": [str(self.consumer)]}}, INVENTORY, self.hub)
        self.assertEqual(set(combined), set(defaults) | {Checkout("owner/consumer", self.consumer), Checkout("owner/consumer", consumer_tree)})

    def test_platform_alias_dedup_and_one_bounded_discovery_deadline(self):
        alias = self.root / "alias"; alias.symlink_to(self.consumer)
        calls = []
        def discovery(path, repo, **kwargs):
            calls.append((path, repo, kwargs))
            return (Checkout(repo, path), Checkout(repo, path))
        with patch("mergepath.cockpit.agents.discover_checkouts", side_effect=discovery):
            checkouts, _ = resolve_history_settings({"checkouts": {"owner/consumer": [str(self.consumer), str(alias), str(self.consumer)]}}, INVENTORY, self.hub)
        self.assertEqual(len(checkouts), 2)
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0][2]["deadline"], calls[1][2]["deadline"])
        self.assertLessEqual(calls[0][2]["deadline"] - time.monotonic(), 5)

    def test_malformed_unknown_relative_and_missing_configuration_refused(self):
        invalid = [None, [], {"unknown": 1}, {"checkouts": []}, {"checkouts": {"outsider/repo": [str(self.hub)]}},
                   {"checkouts": {REPO: "path"}}, {"checkouts": {REPO: []}}, {"checkouts": {REPO: [1]}},
                   {"checkouts": {REPO: ["relative"]}}, {"checkouts": {REPO: [str(self.root / "missing")]}},
                   {"price_keys": []}, {"price_keys": {"other": "openai.gpt-5.3-codex.standard"}}]
        with patch("mergepath.cockpit.agents.discover_checkouts") as discovery:
            for settings in invalid:
                with self.subTest(settings=settings), self.assertRaises(ValueError):
                    resolve_history_settings(settings, INVENTORY, self.hub)
            discovery.assert_not_called()

    def test_ambiguous_physical_checkout_cannot_be_attributed_to_two_repositories(self):
        with patch("mergepath.cockpit.agents.discover_checkouts", side_effect=lambda path, repo, **kwargs: (Checkout(repo, self.hub),)):
            with self.assertRaises(ValueError):
                resolve_history_settings({"checkouts": {"owner/consumer": [str(self.consumer)]}}, INVENTORY, self.hub)

    def test_global_checkout_cap_includes_all_discovered_roots(self):
        found = tuple(Checkout(REPO, self.root / f"tree-{i}") for i in range(64))
        with patch("mergepath.cockpit.agents.discover_checkouts", return_value=found), self.assertRaises(ValueError):
            resolve_history_settings({}, INVENTORY, self.hub)
        found = (Checkout(REPO, self.hub), *found[:63])
        with patch("mergepath.cockpit.agents.discover_checkouts", return_value=found):
            checkouts, _ = resolve_history_settings({}, INVENTORY, self.hub)
        self.assertEqual(len(checkouts), 64)

    def test_only_explicit_existing_matching_provider_model_tier_prices(self):
        keys = {"codex": "openai.gpt-5.5.standard_short_context", "claude": "anthropic.claude-sonnet-4.6.standard"}
        with patch("mergepath.cockpit.agents.discover_checkouts", return_value=(Checkout(REPO, ROOT),)):
            _, actual = resolve_history_settings({"price_keys": keys}, INVENTORY, ROOT)
            self.assertEqual(dict(actual), keys)
            keys["claude"] = "changed"
            self.assertEqual(actual["claude"], "anthropic.claude-sonnet-4.6.standard")
            for value in (None, 1, "anthropic.claude-sonnet-4.6.standard", "openai.unknown.standard", "openai.gpt-5.5", "openai.gpt-5.5.standard_short_context.input"):
                with self.subTest(value=value), self.assertRaises(ValueError):
                    resolve_history_settings({"price_keys": {"codex": value}}, INVENTORY, ROOT)

    def test_canonical_prices_read_refuses_symlink_and_malformed_table(self):
        directory = self.hub / "scripts/phase-4b"; directory.mkdir(parents=True)
        target = directory / "prices.json"
        outside = self.root / "outside.json"; outside.write_text("private contents")
        target.symlink_to(outside)
        settings = {"price_keys": {"codex": "openai.gpt-5.3-codex.standard"}}
        with self.assertRaises(OSError):
            resolve_history_settings(settings, INVENTORY, self.hub)
        target.unlink()
        for table in ([], {"providers": []}, {"providers": {"openai": {"models": []}}}):
            target.write_text(json.dumps(table))
            with self.subTest(table=table), self.assertRaises(ValueError):
                resolve_history_settings(settings, INVENTORY, self.hub)


def serve_fixture():
    """Temporary real authenticated server for browser QA; all source/upstream data is fake."""
    with tempfile.TemporaryDirectory(prefix="cockpit-agents-fixture-") as directory:
        base = Path(directory).resolve()
        checkout = base / "checkout"
        checkout.mkdir()
        now = int(time.time())
        for index in range(8):
            value = loop("p4b-browser-" + str(index), "claude" if index % 2 == 0 else "codex", 40000 + index * 5000,
                         "APPROVED" if index % 3 == 0 else "CHANGES_REQUESTED" if index % 3 == 1 else "UNAVAILABLE", now - index * 86400)
            value["findings"]["P2"] = index % 3
            if index % 2 == 0:
                value["tokens"].update(input=35000, output=5000, cache_read=10000, cost_usd=.22 + index * .02)
            write_loop(checkout, value, f"owner-hub-pr{1 + index % 3}.jsonl")
        static = base / "static"
        shutil.copytree(ROOT / "mergepath/cockpit", static)
        index = static / "index.html"
        source = index.read_text()
        if 'src="assets/agents.js"' not in source:
            source = source.replace('</head>', '<link rel="stylesheet" href="assets/agents.css"><script src="assets/agents.js" defer></script></head>')
            index.write_text(source)
        class DeniedClient:
            def pages(self, *args, **kwargs):
                raise ClientError("permission_denied")
        client = GitHubClient("fixture-only-token", transport=lambda *a, **k: (_ for _ in ()).throw(AssertionError("upstream refused")))
        provider = AgentsProvider(INVENTORY, (Checkout(REPO, checkout),), ROOT, github=DeniedClient(),
                                  price_keys={"codex": "openai.gpt-5.3-codex.standard"})
        app = Application(INVENTORY, client, static_root=static)
        app.scheduler.register("agents", provider.fetch, hot_interval=5, idle_interval=5, timeout=20)
        app.register_panel("history", "agents")
        server = CockpitServer(app)
        print(json.dumps({"fixture": "synthetic-only", "url": app.launch_url(server.server_address[1]), "checkout": str(checkout)}), flush=True)
        app.scheduler.start()
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            app.close(); server.server_close()


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--serve-fixture":
        serve_fixture()
    else:
        unittest.main()
