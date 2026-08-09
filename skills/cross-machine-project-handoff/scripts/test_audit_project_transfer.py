from __future__ import annotations

import copy
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import audit_project_transfer as transfer


def run_git(repo: Path, *args: str) -> str:
    completed = subprocess.run(
        ["git", *args],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    return completed.stdout.strip()


class ProjectTransferAuditTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temp = tempfile.TemporaryDirectory()
        self.repo = Path(self._temp.name) / "workspace"
        self.repo.mkdir()
        run_git(self.repo, "init", "-b", "main")
        run_git(self.repo, "config", "user.name", "Transfer Test")
        run_git(self.repo, "config", "user.email", "transfer@example.test")
        (self.repo / ".gitignore").write_text(
            ".env\n.mcp.json\n.claude/settings.local.json\nbuild/\n",
            encoding="utf-8",
        )
        (self.repo / "tracked.txt").write_text("base\n", encoding="utf-8")
        run_git(self.repo, "add", ".gitignore", "tracked.txt")
        run_git(self.repo, "commit", "-m", "initial")

    def tearDown(self) -> None:
        self._temp.cleanup()

    def audit(self) -> dict:
        return transfer.audit_workspace(self.repo, scan_absolute_paths=False)

    def test_audit_records_exact_dirty_state_without_exposing_secret_values(self) -> None:
        run_git(
            self.repo,
            "remote",
            "add",
            "origin",
            "https://alice:REMOTE_TOKEN_SHOULD_NOT_LEAK@example.com/org/repo.git",
        )
        (self.repo / "tracked.txt").write_text("stash state\n", encoding="utf-8")
        run_git(self.repo, "stash", "push", "-m", "portable stash")

        (self.repo / "tracked.txt").write_text("staged state\n", encoding="utf-8")
        run_git(self.repo, "add", "tracked.txt")
        (self.repo / "tracked.txt").write_text(
            "staged state\nunstaged state\n", encoding="utf-8"
        )
        (self.repo / "untracked.txt").write_text("untracked\n", encoding="utf-8")
        (self.repo / ".env").write_text(
            "API_TOKEN=FILE_SECRET_SHOULD_NOT_LEAK\n", encoding="utf-8"
        )

        manifest = self.audit()
        serialized = json.dumps(manifest, ensure_ascii=False)
        worktree = {
            item["path"]: item for item in manifest["portable"]["git"]["worktree"]
        }

        self.assertEqual(manifest["format"], "cross-machine-project-handoff-manifest")
        self.assertEqual(manifest["format_version"], "1.0")
        self.assertEqual(
            manifest["comparison_profile"], "git-transferable-state-v1"
        )
        self.assertEqual(manifest["portable"]["git"]["head"]["ref"], "refs/heads/main")
        self.assertEqual(worktree["tracked.txt"]["index"]["state"], "modified")
        self.assertIn("oid", worktree["tracked.txt"]["index"])
        self.assertEqual(worktree["tracked.txt"]["working"]["state"], "modified")
        self.assertIn("sha256", worktree["tracked.txt"]["working"])
        self.assertEqual(worktree["untracked.txt"]["working"]["state"], "untracked")
        self.assertIn("sha256", worktree["untracked.txt"]["working"])
        self.assertEqual(len(manifest["portable"]["git"]["refs"]["stashes"]), 1)
        self.assertEqual(
            manifest["machine_local"]["git"]["remotes"][0]["url"],
            "https://example.com/<redacted>",
        )
        env_record = next(
            item
            for item in manifest["portable"]["sensitive_paths"]
            if item["path"] == ".env"
        )
        self.assertEqual(set(env_record), {"path", "exists", "ignored"})
        self.assertTrue(env_record["exists"])
        self.assertTrue(env_record["ignored"])
        self.assertNotIn(".env", worktree)
        self.assertNotIn("REMOTE_TOKEN_SHOULD_NOT_LEAK", serialized)
        self.assertNotIn("FILE_SECRET_SHOULD_NOT_LEAK", serialized)

    def test_remote_sanitization_never_falls_back_to_a_credential_bearing_url(
        self,
    ) -> None:
        remotes = {
            "helper": "ext::https://alice:HELPER_LEAK@example.com/org/repo.git",
            "scp": "git@example.com:org/repo.git?token=SCP_LEAK",
            "ambiguous-scp": "user@MULTI_AT_LEAK@host:path",
            "file": "file:///Users/alice/FILE_PATH_LEAK/repo.git",
            "opaque": "custom-value-with-OPAQUE_LEAK",
        }
        for name, url in remotes.items():
            run_git(self.repo, "remote", "add", name, url)

        manifest = self.audit()
        serialized = json.dumps(manifest["machine_local"]["git"]["remotes"])

        for sentinel in (
            "HELPER_LEAK",
            "SCP_LEAK",
            "MULTI_AT_LEAK",
            "FILE_PATH_LEAK",
            "OPAQUE_LEAK",
        ):
            self.assertNotIn(sentinel, serialized)

    def test_absolute_path_scan_reports_location_but_not_matched_value(self) -> None:
        (self.repo / "paths.md").write_text(
            "old mac path: /Users/alice/private/project\n"
            "old windows path: D:\\secret\\project\n",
            encoding="utf-8",
        )
        run_git(self.repo, "add", "paths.md")
        run_git(self.repo, "commit", "-m", "add path fixtures")

        manifest = transfer.audit_workspace(self.repo, scan_absolute_paths=True)
        findings = manifest["machine_local"]["portability"]["absolute_path_findings"]
        serialized = json.dumps(findings, ensure_ascii=False)

        self.assertEqual(
            {(item["path"], item["line"], item["kind"]) for item in findings},
            {
                ("paths.md", 1, "posix-user-home"),
                ("paths.md", 2, "windows-drive"),
            },
        )
        self.assertNotIn("alice", serialized)
        self.assertNotIn("secret", serialized)

    def test_dependency_hash_changes_when_lockfile_changes(self) -> None:
        lockfile = self.repo / "pubspec.lock"
        lockfile.write_text("packages: {}\n", encoding="utf-8")
        first = self.audit()
        lockfile.write_text("packages:\n  sample: 1\n", encoding="utf-8")
        second = self.audit()

        first_hash = next(
            item["sha256"]
            for item in first["portable"]["dependency_manifests"]
            if item["path"] == "pubspec.lock"
        )
        second_hash = next(
            item["sha256"]
            for item in second["portable"]["dependency_manifests"]
            if item["path"] == "pubspec.lock"
        )
        self.assertNotEqual(first_hash, second_hash)

    def test_same_dirty_path_with_different_bytes_is_a_mismatch(self) -> None:
        path = self.repo / "untracked.txt"
        path.write_text("source bytes\n", encoding="utf-8")
        source = self.audit()
        path.write_text("target bytes\n", encoding="utf-8")
        target = self.audit()

        report = transfer.compare_manifests(source, target)

        self.assertEqual(report["status"], "mismatch")
        self.assertIn("portable.git.worktree", {item["field"] for item in report["failures"]})

    def test_nfd_untracked_path_uses_raw_path_for_content_hashing(self) -> None:
        path = self.repo / "cafe\u0301.txt"
        path.write_text("one\n", encoding="utf-8")
        first = self.audit()
        path.write_text("two\n", encoding="utf-8")
        second = self.audit()
        first_record = next(
            item
            for item in first["portable"]["git"]["worktree"]
            if item["path"] == "café.txt"
        )
        second_record = next(
            item
            for item in second["portable"]["git"]["worktree"]
            if item["path"] == "café.txt"
        )

        self.assertEqual(first_record["kind"], "file")
        self.assertIn("sha256", first_record["working"])
        self.assertNotEqual(
            first_record["working"]["sha256"], second_record["working"]["sha256"]
        )
        self.assertEqual(
            transfer.compare_manifests(first, second)["status"], "mismatch"
        )

    def test_worktree_record_includes_executable_semantics(self) -> None:
        (self.repo / "tool.sh").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        source = self.audit()
        record = next(
            item
            for item in source["portable"]["git"]["worktree"]
            if item["path"] == "tool.sh"
        )

        self.assertIn("executable", record["working"])
        target = copy.deepcopy(source)
        target_record = next(
            item
            for item in target["portable"]["git"]["worktree"]
            if item["path"] == "tool.sh"
        )
        target_record["working"]["executable"] = not record["working"]["executable"]
        self.assertEqual(
            transfer.compare_manifests(source, target)["status"], "mismatch"
        )

    def test_verify_allows_machine_local_differences_and_warns_for_secrets(self) -> None:
        (self.repo / ".env").write_text("LOCAL_ONLY=one\n", encoding="utf-8")
        source = self.audit()
        target = copy.deepcopy(source)
        target["created_at"] = "2030-01-01T00:00:00Z"
        target["machine_local"]["machine"]["os"] = "DifferentOS"
        target["machine_local"]["workspace"]["root"] = "/different/workspace"

        report = transfer.compare_manifests(source, target)

        self.assertEqual(report["status"], "match_with_warnings")
        self.assertEqual(report["failures"], [])
        self.assertGreaterEqual(len(report["warnings"]), 1)

    def test_verify_fails_for_missing_portable_git_or_dependency_state(self) -> None:
        (self.repo / "tracked.txt").write_text("stash fixture\n", encoding="utf-8")
        run_git(self.repo, "stash", "push", "-m", "verify fixture")
        (self.repo / "pubspec.lock").write_text("packages: {}\n", encoding="utf-8")
        source = self.audit()
        mutations = {
            "different HEAD": lambda target: target["portable"]["git"]["head"].update(
                {"oid": "0" * 40}
            ),
            "missing stash": lambda target: target["portable"]["git"]["refs"].update(
                {"stashes": []}
            ),
            "different worktree": lambda target: target["portable"]["git"][
                "worktree"
            ][0].update({"path": "lost.txt"}),
            "different dependency": lambda target: target["portable"][
                "dependency_manifests"
            ][0].update({"sha256": "f" * 64}),
        }

        for label, mutate in mutations.items():
            with self.subTest(label=label):
                target = copy.deepcopy(source)
                mutate(target)
                self.assertEqual(
                    transfer.compare_manifests(source, target)["status"], "mismatch"
                )

    def test_audit_records_local_branches_and_tags(self) -> None:
        run_git(self.repo, "branch", "offline-work")
        run_git(self.repo, "tag", "transfer-checkpoint")

        manifest = self.audit()
        refs = manifest["portable"]["git"]["refs"]

        self.assertEqual(
            {item["name"] for item in refs["heads"]},
            {"refs/heads/main", "refs/heads/offline-work"},
        )
        self.assertEqual(
            {item["name"] for item in refs["tags"]},
            {"refs/tags/transfer-checkpoint"},
        )

    def test_audit_records_non_remote_custom_refs(self) -> None:
        run_git(self.repo, "update-ref", "refs/notes/review", "HEAD")
        source = self.audit()
        run_git(self.repo, "update-ref", "-d", "refs/notes/review")
        target = self.audit()

        self.assertEqual(
            {item["name"] for item in source["portable"]["git"]["refs"]["other"]},
            {"refs/notes/review"},
        )
        self.assertEqual(
            transfer.compare_manifests(source, target)["status"], "mismatch"
        )

    def test_hidden_index_flags_and_hidden_working_bytes_are_audited(self) -> None:
        clean = self.audit()
        run_git(self.repo, "update-index", "--assume-unchanged", "tracked.txt")
        (self.repo / "tracked.txt").write_text("hidden change\n", encoding="utf-8")

        hidden = self.audit()

        self.assertEqual(
            hidden["portable"]["git"]["index_flags"],
            [
                {
                    "path": "tracked.txt",
                    "assume_unchanged": True,
                    "skip_worktree": False,
                }
            ],
        )
        hidden_record = next(
            item
            for item in hidden["portable"]["git"]["worktree"]
            if item["path"] == "tracked.txt"
        )
        self.assertIn("sha256", hidden_record["working"])
        self.assertEqual(
            transfer.compare_manifests(clean, hidden)["status"], "mismatch"
        )

    def test_sensitive_presence_and_ignore_state_are_safety_requirements(self) -> None:
        (self.repo / ".env").write_text("VALUE=not-compared\n", encoding="utf-8")
        source = self.audit()

        missing = copy.deepcopy(source)
        missing["portable"]["sensitive_paths"] = []
        exposed = copy.deepcopy(source)
        exposed["portable"]["sensitive_paths"][0]["ignored"] = False

        self.assertEqual(
            transfer.compare_manifests(source, missing)["status"], "mismatch"
        )
        self.assertEqual(
            transfer.compare_manifests(source, exposed)["status"], "mismatch"
        )

        absent = copy.deepcopy(source)
        absent["portable"]["sensitive_paths"][0] = {
            "path": ".env",
            "exists": False,
            "ignored": None,
        }
        self.assertEqual(
            transfer.compare_manifests(source, absent)["status"], "mismatch"
        )

    def test_builtin_and_declared_sensitive_paths_are_never_hashed(self) -> None:
        with (self.repo / ".gitignore").open("a", encoding="utf-8") as ignore_file:
            ignore_file.write(
                ".git-credentials\nconfig/private.toml\nconfig/private-*.json\n"
                "nested/.npmrc\n.aws/credentials\n"
            )
        (self.repo / "nested").mkdir()
        (self.repo / ".aws").mkdir()
        (self.repo / "config").mkdir()
        fixtures = {
            ".git-credentials": "BUILTIN_GIT_SECRET",
            "nested/.npmrc": "BUILTIN_NPM_SECRET",
            ".aws/credentials": "BUILTIN_AWS_SECRET",
            "config/private.toml": "DECLARED_PRIVATE_SECRET",
            "config/private-prod.json": "DECLARED_GLOB_SECRET",
        }
        for relative, secret in fixtures.items():
            (self.repo / relative).write_text(secret, encoding="utf-8")

        manifest = transfer.audit_workspace(
            self.repo,
            scan_absolute_paths=False,
            sensitive_paths=["config/private.toml"],
            sensitive_globs=["config/private-*.json"],
        )
        serialized = json.dumps(manifest, ensure_ascii=False)
        sensitive_paths = {
            item["path"] for item in manifest["portable"]["sensitive_paths"]
        }
        worktree_paths = {
            item["path"] for item in manifest["portable"]["git"]["worktree"]
        }

        self.assertTrue(set(fixtures).issubset(sensitive_paths))
        self.assertTrue(set(fixtures).isdisjoint(worktree_paths))
        for secret in fixtures.values():
            self.assertNotIn(secret, serialized)

    def test_declared_sensitive_directory_protects_descendants_and_target_presence(
        self,
    ) -> None:
        private_dir = self.repo / "private"
        private_dir.mkdir()
        secret_file = private_dir / "token.txt"
        secret_file.write_text("DIRECTORY_SECRET_SENTINEL", encoding="utf-8")

        exposed_source = transfer.audit_workspace(
            self.repo,
            scan_absolute_paths=False,
            sensitive_paths=["private"],
        )
        exposed_serialized = json.dumps(exposed_source, ensure_ascii=False)
        self.assertIn(
            "private/token.txt",
            {
                item["path"]
                for item in exposed_source["portable"]["sensitive_paths"]
            },
        )
        self.assertNotIn(
            "private/token.txt",
            {
                item["path"]
                for item in exposed_source["portable"]["git"]["worktree"]
            },
        )
        self.assertNotIn("DIRECTORY_SECRET_SENTINEL", exposed_serialized)

        with (self.repo / ".gitignore").open("a", encoding="utf-8") as ignore_file:
            ignore_file.write("private/\n")
        source = transfer.audit_workspace(
            self.repo,
            scan_absolute_paths=False,
            sensitive_paths=["private"],
        )
        secret_file.unlink()
        private_dir.rmdir()
        target = transfer.audit_workspace(
            self.repo,
            scan_absolute_paths=False,
            sensitive_paths=["private"],
        )

        self.assertEqual(
            transfer.compare_manifests(source, target)["status"], "mismatch"
        )

    def test_explicit_sensitive_rules_override_rebuildable_directory_pruning(
        self,
    ) -> None:
        with (self.repo / ".gitignore").open("a", encoding="utf-8") as ignore_file:
            ignore_file.write("dist/\n")
        build_dir = self.repo / "build"
        dist_dir = self.repo / "dist"
        build_dir.mkdir()
        dist_dir.mkdir()
        build_secret = build_dir / "signing-secret.txt"
        glob_secret = dist_dir / "release-key.pem"
        build_secret.write_text("BUILD_SECRET_SENTINEL", encoding="utf-8")
        glob_secret.write_text("GLOB_SECRET_SENTINEL", encoding="utf-8")

        source = transfer.audit_workspace(
            self.repo,
            scan_absolute_paths=False,
            sensitive_paths=["build"],
            sensitive_globs=["dist/*.pem"],
        )
        serialized = json.dumps(source, ensure_ascii=False)
        sensitive = {
            item["path"] for item in source["portable"]["sensitive_paths"]
        }

        self.assertIn("build", sensitive)
        self.assertIn("build/signing-secret.txt", sensitive)
        self.assertIn("dist/release-key.pem", sensitive)
        self.assertNotIn("BUILD_SECRET_SENTINEL", serialized)
        self.assertNotIn("GLOB_SECRET_SENTINEL", serialized)

        build_secret.unlink()
        glob_secret.unlink()
        build_dir.rmdir()
        dist_dir.rmdir()
        target = transfer.audit_workspace(
            self.repo,
            scan_absolute_paths=False,
            sensitive_paths=["build"],
            sensitive_globs=["dist/*.pem"],
        )

        self.assertEqual(
            transfer.compare_manifests(source, target)["status"], "mismatch"
        )

    def test_unknown_ignored_state_is_reported_without_reading_contents(self) -> None:
        with (self.repo / ".gitignore").open("a", encoding="utf-8") as ignore_file:
            ignore_file.write("supabase/snapshots/\n")
        snapshot_dir = self.repo / "supabase" / "snapshots"
        snapshot_dir.mkdir(parents=True)
        (snapshot_dir / "local.sql").write_text(
            "IGNORED_DATABASE_SECRET", encoding="utf-8"
        )

        manifest = self.audit()
        local_state = manifest["machine_local"]["local_state"]
        serialized = json.dumps(local_state, ensure_ascii=False)

        self.assertIn(
            "supabase/snapshots",
            {item["path"] for item in local_state["ignored_nonrebuildable_paths"]},
        )
        self.assertNotIn("IGNORED_DATABASE_SECRET", serialized)

    def test_shared_editor_settings_are_portable_but_local_settings_are_sensitive(
        self,
    ) -> None:
        editor_dir = self.repo / ".vscode"
        editor_dir.mkdir()
        (editor_dir / "settings.json").write_text(
            '{"editor.formatOnSave": true}\n', encoding="utf-8"
        )
        with (self.repo / ".gitignore").open("a", encoding="utf-8") as ignore_file:
            ignore_file.write(".vscode/settings.local.json\n")
        run_git(self.repo, "add", ".gitignore", ".vscode/settings.json")
        run_git(self.repo, "commit", "-m", "add shared editor settings")
        (editor_dir / "settings.local.json").write_text(
            '{"private.setting": "not-read"}\n', encoding="utf-8"
        )

        manifest = self.audit()
        sensitive = {
            item["path"]: item for item in manifest["portable"]["sensitive_paths"]
        }

        self.assertNotIn(".vscode/settings.json", sensitive)
        self.assertEqual(
            sensitive[".vscode/settings.local.json"],
            {
                "path": ".vscode/settings.local.json",
                "exists": True,
                "ignored": True,
            },
        )

    def test_incomplete_or_incompatible_manifests_are_inconclusive(self) -> None:
        source = self.audit()
        incomplete = copy.deepcopy(source)
        incomplete["coverage"] = {
            "complete": False,
            "limitations": [{"code": "additional-worktree-not-audited"}],
        }
        incompatible = copy.deepcopy(source)
        incompatible["format_version"] = "2.0"

        self.assertEqual(
            transfer.compare_manifests(source, incomplete)["status"], "inconclusive"
        )
        self.assertEqual(
            transfer.compare_manifests(source, incompatible)["status"], "inconclusive"
        )

    def test_malformed_nested_manifest_records_are_inconclusive(self) -> None:
        source = self.audit()
        mutations = {
            "missing object format": lambda target: target["portable"]["git"].pop(
                "object_format"
            ),
            "ref without name": lambda target: target["portable"]["git"][
                "refs"
            ].update({"heads": [{"oid": "0" * 40}]}),
            "invalid digest": lambda target: target["portable"].update(
                {"dependency_manifests": [{"path": "pubspec.lock", "sha256": "bad"}]}
            ),
            "sensitive extra field": lambda target: target["portable"].update(
                {
                    "sensitive_paths": [
                        {
                            "path": ".env",
                            "exists": True,
                            "ignored": True,
                            "sha256": "must-not-exist",
                        }
                    ]
                }
            ),
            "hidden coverage limitation": lambda target: target["coverage"].update(
                {
                    "complete": True,
                    "limitations": [{"code": "must-not-be-hidden"}],
                }
            ),
            "unknown portable field": lambda target: target["portable"].update(
                {"future_semantics": {"required": True}}
            ),
            "untracked path missing digest": lambda target: target["portable"][
                "git"
            ].update(
                {
                    "worktree": [
                        {
                            "path": "vanished.txt",
                            "kind": "missing",
                            "working": {"state": "untracked"},
                        }
                    ]
                }
            ),
        }

        for label, mutate in mutations.items():
            with self.subTest(label=label):
                target = copy.deepcopy(source)
                mutate(target)
                report = transfer.compare_manifests(source, target)
                self.assertEqual(report["status"], "inconclusive")

    def test_path_collision_detection_covers_case_and_unicode_normalization(self) -> None:
        limitations = transfer._path_collision_limitations(
            ["Foo.txt", "foo.txt", "café.md", "cafe\u0301.md"]
        )
        codes = {item["code"] for item in limitations}

        self.assertIn("case-collision", codes)
        self.assertIn("unicode-normalization-collision", codes)

    def test_unmerged_index_marks_coverage_incomplete(self) -> None:
        run_git(self.repo, "checkout", "-b", "conflicting-side")
        (self.repo / "tracked.txt").write_text("side\n", encoding="utf-8")
        run_git(self.repo, "add", "tracked.txt")
        run_git(self.repo, "commit", "-m", "side change")
        run_git(self.repo, "checkout", "main")
        (self.repo / "tracked.txt").write_text("main\n", encoding="utf-8")
        run_git(self.repo, "add", "tracked.txt")
        run_git(self.repo, "commit", "-m", "main change")

        merge = subprocess.run(
            ["git", "merge", "conflicting-side"],
            cwd=self.repo,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        self.assertNotEqual(merge.returncode, 0)

        manifest = self.audit()

        self.assertFalse(manifest["coverage"]["complete"])
        self.assertIn(
            "unmerged-index-not-audited",
            {item["code"] for item in manifest["coverage"]["limitations"]},
        )
        self.assertEqual(
            transfer.compare_manifests(manifest, manifest)["status"], "inconclusive"
        )

    def test_in_progress_merge_marks_coverage_incomplete_without_conflicts(self) -> None:
        run_git(self.repo, "checkout", "-b", "merge-side")
        (self.repo / "side.txt").write_text("side\n", encoding="utf-8")
        run_git(self.repo, "add", "side.txt")
        run_git(self.repo, "commit", "-m", "side file")
        run_git(self.repo, "checkout", "main")
        (self.repo / "main.txt").write_text("main\n", encoding="utf-8")
        run_git(self.repo, "add", "main.txt")
        run_git(self.repo, "commit", "-m", "main file")
        run_git(self.repo, "merge", "--no-commit", "--no-ff", "merge-side")

        manifest = self.audit()

        self.assertFalse(manifest["coverage"]["complete"])
        self.assertIn(
            "git-operation-in-progress-not-audited",
            {item["code"] for item in manifest["coverage"]["limitations"]},
        )

    def test_audit_lists_tracked_document_candidates_without_reading_contents(self) -> None:
        candidate = self.repo / "论文-张三.docx"
        candidate.write_bytes(b"PRIVATE_DOCUMENT_BYTES_MUST_NOT_APPEAR")
        run_git(self.repo, "add", candidate.name)
        run_git(self.repo, "commit", "-m", "add private document fixture")

        manifest = self.audit()
        serialized = json.dumps(manifest, ensure_ascii=False)
        candidates = manifest["machine_local"]["data_review"][
            "tracked_sensitive_candidates"
        ]

        self.assertEqual(
            candidates,
            [
                {
                    "path": candidate.name,
                    "extension": ".docx",
                    "size_bytes": candidate.stat().st_size,
                }
            ],
        )
        self.assertNotIn("PRIVATE_DOCUMENT_BYTES_MUST_NOT_APPEAR", serialized)
        self.assertIn(
            "tracked-sensitive-data-review-required",
            {item["code"] for item in manifest["machine_local"]["risks"]},
        )

    def test_audit_records_compromised_credential_labels_as_blocking_risk(self) -> None:
        manifest = transfer.audit_workspace(
            self.repo,
            scan_absolute_paths=False,
            compromised_credential_labels=["deployment-server-password"],
        )
        serialized = json.dumps(manifest, ensure_ascii=False)

        self.assertEqual(
            manifest["machine_local"]["security"]["compromised_credential_labels"],
            ["deployment-server-password"],
        )
        self.assertIn(
            {"code": "credential-rotation-required", "severity": "blocking"},
            manifest["machine_local"]["risks"],
        )
        self.assertNotIn("password=", serialized.lower())

    def test_codex_environment_inventory_lists_tools_without_reading_config(self) -> None:
        codex_home = Path(self._temp.name) / "home" / ".codex"
        skill_dir = codex_home / "skills" / "sample-skill"
        skill_dir.mkdir(parents=True)
        (skill_dir / "SKILL.md").write_text(
            "---\nname: sample-skill\ndescription: test skill\n---\n",
            encoding="utf-8",
        )
        plugin_dir = (
            codex_home
            / "plugins"
            / "cache"
            / "vendor"
            / "sample-plugin"
            / "1.2.3"
            / ".codex-plugin"
        )
        plugin_dir.mkdir(parents=True)
        (plugin_dir / "plugin.json").write_text(
            json.dumps({"id": "sample-plugin", "version": "1.2.3"}),
            encoding="utf-8",
        )
        (codex_home / "config.toml").write_text(
            'api_token = "CONFIG_SECRET_MUST_NOT_APPEAR"\n',
            encoding="utf-8",
        )
        agents_skill_dir = (
            codex_home.parent / ".agents" / "skills" / "agents-sample-skill"
        )
        agents_skill_dir.mkdir(parents=True)
        (agents_skill_dir / "SKILL.md").write_text(
            "---\nname: agents-sample-skill\ndescription: test skill\n---\n",
            encoding="utf-8",
        )
        (codex_home.parent / ".agents" / "credentials.json").write_text(
            '{"token":"AGENTS_SECRET_MUST_NOT_APPEAR"}', encoding="utf-8"
        )

        inventory = transfer.inventory_codex_environment(codex_home)
        serialized = json.dumps(inventory, ensure_ascii=False)

        self.assertEqual(
            inventory["skills"],
            [{"name": "agents-sample-skill"}, {"name": "sample-skill"}],
        )
        self.assertEqual(
            inventory["plugins"],
            [{"id": "sample-plugin", "version": "1.2.3"}],
        )
        self.assertNotIn("CONFIG_SECRET_MUST_NOT_APPEAR", serialized)
        self.assertNotIn("AGENTS_SECRET_MUST_NOT_APPEAR", serialized)

    def test_pack_refuses_dirty_unknown_ignored_and_compromised_state(self) -> None:
        output = Path(self._temp.name) / "handoff"
        (self.repo / "dirty.txt").write_text("dirty\n", encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "clean worktree"):
            transfer.create_handoff_package(
                self.repo,
                output,
                objective="Continue the project safely.",
                next_action="Run the target audit.",
            )

        (self.repo / "dirty.txt").unlink()
        (self.repo / ".gitignore").write_text(
            (self.repo / ".gitignore").read_text(encoding="utf-8")
            + "private-cache/\n",
            encoding="utf-8",
        )
        run_git(self.repo, "add", ".gitignore")
        run_git(self.repo, "commit", "-m", "ignore private cache")
        (self.repo / "private-cache").mkdir()
        (self.repo / "private-cache" / "state.bin").write_bytes(b"LOCAL_STATE")

        with self.assertRaisesRegex(ValueError, "unclassified ignored"):
            transfer.create_handoff_package(
                self.repo,
                output,
                objective="Continue the project safely.",
                next_action="Run the target audit.",
            )

        shutil.rmtree(self.repo / "private-cache")
        with self.assertRaisesRegex(ValueError, "Rotate compromised credentials"):
            transfer.create_handoff_package(
                self.repo,
                output,
                objective="Continue the project safely.",
                next_action="Run the target audit.",
                compromised_credential_labels=["deployment-password"],
            )

    def test_pack_detects_lfs_attributes_even_when_git_lfs_is_unavailable(self) -> None:
        (self.repo / ".gitattributes").write_text(
            "*.bin filter=lfs diff=lfs merge=lfs -text\n", encoding="utf-8"
        )
        (self.repo / "asset.bin").write_bytes(b"LFS_SOURCE_BYTES")
        run_git(self.repo, "add", ".gitattributes", "asset.bin")
        run_git(self.repo, "commit", "-m", "add lfs fixture")
        original_run = transfer._run

        def run_without_lfs(args: list[str], cwd: Path, *, check: bool = True):
            if args == ["git", "lfs", "version"]:
                return subprocess.CompletedProcess(args, 1, "", "git-lfs unavailable")
            return original_run(args, cwd, check=check)

        with mock.patch.object(transfer, "_run", side_effect=run_without_lfs):
            manifest = self.audit()
            self.assertFalse(manifest["machine_local"]["git"]["lfs"]["available"])
            self.assertEqual(
                manifest["machine_local"]["git"]["lfs"]["files"], ["asset.bin"]
            )
            with self.assertRaisesRegex(ValueError, "Git LFS"):
                transfer.create_handoff_package(
                    self.repo,
                    Path(self._temp.name) / "handoff",
                    objective="Continue safely.",
                    next_action="Restore and verify.",
                )

    def test_pack_requires_explicit_tracked_data_review_approval(self) -> None:
        candidate = self.repo / "student-thesis.docx"
        candidate.write_bytes(b"PRIVATE_FIXTURE")
        run_git(self.repo, "add", candidate.name)
        run_git(self.repo, "commit", "-m", "add reviewed document fixture")
        output = Path(self._temp.name) / "handoff"

        with self.assertRaisesRegex(ValueError, "tracked data review"):
            transfer.create_handoff_package(
                self.repo,
                output,
                objective="Continue the project safely.",
                next_action="Run the target audit.",
            )

        receipt = transfer.create_handoff_package(
            self.repo,
            output,
            objective="Continue the project safely.",
            next_action="Run the target audit.",
            approve_tracked_data_review=True,
        )

        self.assertTrue(receipt["approvals"]["tracked_data_review"])
        self.assertIn(
            "cross-machine-project-handoff", receipt["requirements"]["skills"]
        )
        self.assertEqual(
            receipt["approvals"]["tracked_sensitive_candidates"],
            [{"path": candidate.name, "extension": ".docx", "size_bytes": 15}],
        )

    def test_pack_creates_verified_receipt_capsule_and_prompt(self) -> None:
        codex_home = Path(self._temp.name) / "codex-home"
        skill_dir = codex_home / "skills" / "cross-machine-project-handoff"
        skill_dir.mkdir(parents=True)
        (skill_dir / "SKILL.md").write_text(
            "---\nname: cross-machine-project-handoff\ndescription: transfer\n---\n",
            encoding="utf-8",
        )
        (codex_home / "config.toml").write_text(
            'token = "CONFIG_SECRET_MUST_NOT_APPEAR"\n', encoding="utf-8"
        )
        validation_path = Path(self._temp.name) / "validation.json"
        validation_path.write_text(
            json.dumps(
                [
                    {
                        "name": "unit-tests",
                        "status": "passed",
                        "command_label": "python -m unittest",
                        "exit_code": 0,
                        "summary": "27 tests passed",
                    },
                    {
                        "name": "server-smoke",
                        "status": "timed_out",
                        "summary": "No completion evidence was captured.",
                    },
                ]
            ),
            encoding="utf-8",
        )
        encrypted_archive = Path(self._temp.name) / "project-secrets.7z"
        encrypted_archive.write_bytes(b"ENCRYPTED_ARCHIVE_BYTES")
        output = Path(self._temp.name) / "handoff"

        receipt = transfer.create_handoff_package(
            self.repo,
            output,
            objective="Make requirement-driven thesis formatting production-ready.",
            non_goals=["Do not resume payment work."],
            next_action="Restore, audit, and verify on the target computer.",
            validation_file=validation_path,
            required_skills=["cross-machine-project-handoff"],
            required_docs=["AGENTS.md", "docs/product-direction-and-current-focus.md"],
            encrypted_secret_archive=encrypted_archive,
            confirm_secret_archive_encrypted=True,
            codex_home=codex_home,
        )
        serialized = json.dumps(receipt, ensure_ascii=False)

        for filename in (
            "repository.bundle",
            "source-manifest.json",
            "handoff-receipt.json",
            "handoff-capsule.txt",
            "new-session-prompt.txt",
            "encrypted-secrets.7z",
        ):
            self.assertTrue((output / filename).is_file(), filename)
        self.assertEqual(receipt["source"]["head_oid"], run_git(self.repo, "rev-parse", "HEAD"))
        self.assertEqual(
            receipt["artifacts"]["repository_bundle"]["sha256"],
            transfer._sha256_file(output / "repository.bundle"),
        )
        self.assertEqual(
            [item["status"] for item in receipt["validation"]],
            ["passed", "timed_out"],
        )
        self.assertTrue(receipt["security"]["encrypted_secret_archive_user_attested"])
        self.assertEqual(
            receipt["security"]["encrypted_secret_archive_cryptographic_verification"],
            "not_performed",
        )
        prompt = (output / "new-session-prompt.txt").read_text(encoding="utf-8")
        self.assertIn("cross-machine-project-handoff", prompt)
        self.assertIn(receipt["source"]["head_oid"], prompt)
        self.assertNotIn("CONFIG_SECRET_MUST_NOT_APPEAR", serialized + prompt)

    def test_pack_requires_user_attestation_for_encrypted_secret_archive(self) -> None:
        archive = Path(self._temp.name) / "claimed-encrypted.7z"
        archive.write_bytes(b"OPAQUE_ARCHIVE_FIXTURE")
        output = Path(self._temp.name) / "handoff"

        with self.assertRaisesRegex(ValueError, "confirm.*encrypted"):
            transfer.create_handoff_package(
                self.repo,
                output,
                objective="Continue safely.",
                next_action="Restore and verify.",
                encrypted_secret_archive=archive,
            )

        self.assertFalse(output.exists())

    def test_pack_rejects_missing_encrypted_archive_before_creating_output(self) -> None:
        output = Path(self._temp.name) / "handoff"

        with self.assertRaisesRegex(ValueError, "Encrypted secret archive"):
            transfer.create_handoff_package(
                self.repo,
                output,
                objective="Continue safely.",
                next_action="Restore and verify.",
                encrypted_secret_archive=Path(self._temp.name) / "missing.7z",
                confirm_secret_archive_encrypted=True,
            )

        self.assertFalse(output.exists())

    def test_restore_refuses_nonempty_target_and_recreates_clean_git_state(self) -> None:
        run_git(self.repo, "tag", "v1")
        head_oid = run_git(self.repo, "rev-parse", "HEAD")
        run_git(self.repo, "update-ref", "refs/archive/snapshot", head_oid)
        package_dir = Path(self._temp.name) / "handoff"
        receipt = transfer.create_handoff_package(
            self.repo,
            package_dir,
            objective="Continue the project safely.",
            next_action="Run the target audit.",
        )
        receipt_path = package_dir / "handoff-receipt.json"
        target = Path(self._temp.name) / "restored"
        target.mkdir()
        (target / "occupied.txt").write_text("do not overwrite\n", encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "empty or absent"):
            transfer.restore_handoff_package(
                receipt_path,
                target,
                output_dir=Path(self._temp.name) / "restore-evidence",
            )

        (target / "occupied.txt").unlink()
        report = transfer.restore_handoff_package(
            receipt_path,
            target,
            output_dir=Path(self._temp.name) / "restore-evidence",
        )

        self.assertEqual(report["status"], "restored_and_manifest_match")
        self.assertEqual(run_git(target, "rev-parse", "HEAD"), receipt["source"]["head_oid"])
        self.assertEqual(run_git(target, "rev-parse", "refs/tags/v1"), head_oid)
        self.assertEqual(run_git(target, "rev-parse", "refs/archive/snapshot"), head_oid)
        self.assertTrue((Path(self._temp.name) / "restore-evidence" / "target-manifest.json").is_file())

    def test_restore_reports_sensitive_state_as_pending_until_separate_restore(self) -> None:
        (self.repo / ".env").write_text(
            "TOKEN=SECRET_VALUE_MUST_NOT_APPEAR\n", encoding="utf-8"
        )
        package_dir = Path(self._temp.name) / "handoff"
        transfer.create_handoff_package(
            self.repo,
            package_dir,
            objective="Continue the project safely.",
            next_action="Restore the encrypted sensitive package, then verify.",
        )

        target = Path(self._temp.name) / "restored"
        report = transfer.restore_handoff_package(
            package_dir / "handoff-receipt.json",
            target,
            output_dir=Path(self._temp.name) / "restore-evidence",
        )
        serialized = json.dumps(report, ensure_ascii=False)

        self.assertEqual(report["status"], "awaiting_sensitive_restore")
        self.assertFalse((target / ".env").exists())
        self.assertNotIn("SECRET_VALUE_MUST_NOT_APPEAR", serialized)

    def test_restore_rejects_inconsistent_or_malformed_receipt_before_clone(self) -> None:
        package_dir = Path(self._temp.name) / "handoff"
        transfer.create_handoff_package(
            self.repo,
            package_dir,
            objective="Continue safely.",
            next_action="Restore and verify.",
        )
        receipt_path = package_dir / "handoff-receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["source"]["head_oid"] = "0" * 40
        receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
        target = Path(self._temp.name) / "restored"

        with self.assertRaisesRegex(ValueError, "receipt source identity"):
            transfer.restore_handoff_package(
                receipt_path,
                target,
                output_dir=Path(self._temp.name) / "restore-evidence",
            )
        self.assertFalse(target.exists())

        receipt["source"]["head_oid"] = run_git(self.repo, "rev-parse", "HEAD")
        receipt["requirements"]["skills"] = None
        receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "receipt requirements"):
            transfer.restore_handoff_package(
                receipt_path,
                target,
                output_dir=Path(self._temp.name) / "restore-evidence",
            )
        self.assertFalse(target.exists())

    def test_validation_evidence_rejects_unknown_status(self) -> None:
        validation_path = Path(self._temp.name) / "validation.json"
        validation_path.write_text(
            json.dumps([{"name": "tests", "status": "maybe"}]),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(ValueError, "validation status"):
            transfer.create_handoff_package(
                self.repo,
                Path(self._temp.name) / "handoff",
                objective="Continue the project safely.",
                next_action="Run the target audit.",
                validation_file=validation_path,
            )

    def test_cli_pack_and_restore_create_a_verifiable_clean_handoff(self) -> None:
        script = SCRIPT_DIR / "audit_project_transfer.py"
        package_dir = Path(self._temp.name) / "cli-handoff"
        pack = subprocess.run(
            [
                sys.executable,
                str(script),
                "pack",
                "--workspace",
                str(self.repo),
                "--output-dir",
                str(package_dir),
                "--objective",
                "Continue safely.",
                "--next-action",
                "Restore and verify.",
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        self.assertEqual(pack.returncode, 0, pack.stderr)
        self.assertEqual(json.loads(pack.stdout)["format"], transfer.HANDOFF_FORMAT)

        target = Path(self._temp.name) / "cli-restored"
        evidence = Path(self._temp.name) / "cli-restore-evidence"
        restore = subprocess.run(
            [
                sys.executable,
                str(script),
                "restore",
                "--receipt",
                str(package_dir / "handoff-receipt.json"),
                "--target",
                str(target),
                "--output-dir",
                str(evidence),
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        self.assertEqual(restore.returncode, 0, restore.stderr)
        self.assertEqual(
            json.loads(restore.stdout)["status"], "restored_and_manifest_match"
        )

    def test_cli_uses_zero_one_and_two_for_match_mismatch_and_inconclusive(self) -> None:
        script = SCRIPT_DIR / "audit_project_transfer.py"
        source_path = Path(self._temp.name) / "source.json"
        target_path = Path(self._temp.name) / "target.json"

        audit = subprocess.run(
            [
                sys.executable,
                str(script),
                "audit",
                "--workspace",
                str(self.repo),
                "--output",
                str(source_path),
                "--no-absolute-path-scan",
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        self.assertEqual(audit.returncode, 0, audit.stderr)
        target_path.write_text(source_path.read_text(encoding="utf-8"), encoding="utf-8")

        verify_match = subprocess.run(
            [sys.executable, str(script), "verify", "--source", str(source_path), "--target", str(target_path)],
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        self.assertEqual(verify_match.returncode, 0, verify_match.stderr)
        self.assertIn(json.loads(verify_match.stdout)["status"], {"match", "match_with_warnings"})

        invalid = json.loads(target_path.read_text(encoding="utf-8"))
        invalid["portable"]["git"].pop("object_format")
        target_path.write_text(json.dumps(invalid), encoding="utf-8")
        verify_invalid = subprocess.run(
            [
                sys.executable,
                str(script),
                "verify",
                "--source",
                str(source_path),
                "--target",
                str(target_path),
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        self.assertEqual(verify_invalid.returncode, 2)
        self.assertEqual(json.loads(verify_invalid.stdout)["status"], "inconclusive")
        self.assertNotIn("Traceback", verify_invalid.stderr)

        target = json.loads(source_path.read_text(encoding="utf-8"))
        target["portable"]["git"]["head"]["oid"] = "0" * 40
        target_path.write_text(json.dumps(target), encoding="utf-8")
        verify_mismatch = subprocess.run(
            [sys.executable, str(script), "verify", "--source", str(source_path), "--target", str(target_path)],
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        self.assertEqual(verify_mismatch.returncode, 1)

        target["coverage"] = {"complete": False, "limitations": [{"code": "test"}]}
        target_path.write_text(json.dumps(target), encoding="utf-8")
        verify_inconclusive = subprocess.run(
            [sys.executable, str(script), "verify", "--source", str(source_path), "--target", str(target_path)],
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        self.assertEqual(verify_inconclusive.returncode, 2)


if __name__ == "__main__":
    unittest.main()
