from __future__ import annotations

import copy
import json
import shutil
import subprocess
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SOURCE_SCRIPTS = REPOSITORY_ROOT / "skills" / "yefeng" / "scripts"
POWERSHELL = shutil.which("pwsh") or shutil.which("powershell")
WINDOWS_POWERSHELL = shutil.which("powershell")


class MessageBrokerIntegrationTests(unittest.TestCase):
    """Prove the yefeng runtime bus with real processes and filesystem state."""

    @classmethod
    def setUpClass(cls) -> None:
        if POWERSHELL is None:
            raise RuntimeError("pwsh or powershell is required")

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="yefeng-broker-", ignore_cleanup_errors=True
        )
        self.addCleanup(self.temporary_directory.cleanup)
        self.fixture_root = Path(self.temporary_directory.name)
        self.control, self.product, self.scope_id, self.assignments = (
            self._create_active_control()
        )

    def _run(
        self,
        command: list[str],
        *,
        cwd: Path | None = None,
        check: bool = True,
        timeout: int = 60,
    ) -> subprocess.CompletedProcess[str]:
        completed = subprocess.run(
            command,
            cwd=cwd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
        )
        if check and completed.returncode != 0:
            self.fail(
                f"command failed with {completed.returncode}: {' '.join(command)}\n"
                f"stdout: {completed.stdout}\nstderr: {completed.stderr}"
            )
        return completed

    def _git(self, root: Path, *arguments: str, check: bool = True) -> str:
        return self._run(["git", *arguments], cwd=root, check=check).stdout.strip()

    def _ps(
        self,
        script: Path,
        *arguments: str,
        engine: str | None = None,
        check: bool = True,
        timeout: int = 60,
    ) -> subprocess.CompletedProcess[str]:
        selected_engine = engine or POWERSHELL
        assert selected_engine is not None
        return self._run(
            [selected_engine, "-NoLogo", "-NoProfile", "-File", str(script), *arguments],
            check=check,
            timeout=timeout,
        )

    def _json_output(self, completed: subprocess.CompletedProcess[str]) -> dict[str, Any]:
        try:
            return json.loads(completed.stdout.lstrip("\ufeff").strip())
        except json.JSONDecodeError as error:
            self.fail(
                f"PowerShell output is not JSON: {error}\n"
                f"stdout: {completed.stdout}\nstderr: {completed.stderr}"
            )

    def _read_json(self, path: Path) -> dict[str, Any]:
        return json.loads(path.read_text(encoding="utf-8"))

    def _write_json(self, path: Path, value: dict[str, Any]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )

    def _create_product(self) -> Path:
        product = self.fixture_root / "product"
        product.mkdir()
        self._git(product, "init", "--initial-branch=main")
        self._git(product, "config", "user.name", "Yefeng Broker Test")
        self._git(product, "config", "user.email", "broker-test@example.invalid")
        self._git(product, "commit", "--allow-empty", "-m", "product baseline")
        return product

    def _create_active_control(
        self,
    ) -> tuple[Path, Path, str, dict[str, Path]]:
        product = self._create_product()
        control = self.fixture_root / "control"
        scope_id = "scope-broker"
        self._ps(
            SOURCE_SCRIPTS / "init-external-control-repo.ps1",
            "-ControlRoot",
            str(control),
            "-ProductRoot",
            str(product),
            "-ProductBranch",
            "main",
            "-ProjectName",
            "Yefeng Broker",
            "-ProjectId",
            "broker-project",
            "-ScopeId",
            scope_id,
            "-ModuleGoal",
            "Validate single-writer process communication.",
        )
        self._git(control, "config", "user.name", "Yefeng Broker Test")
        self._git(control, "config", "user.email", "broker-test@example.invalid")

        state_root = control / ".yefeng" / "series" / scope_id / "state"
        control_path = state_root / "control.json"
        roles_path = state_root / "roles.json"
        runs_path = state_root / "runs.json"
        control_state = self._read_json(control_path)
        roles_state = self._read_json(roles_path)
        runs_state = self._read_json(runs_path)
        control_state["startup_level"] = "LEVEL_3_FULL_PARALLEL_YEFENG"
        control_state["updated_at"] = datetime.now(timezone.utc).isoformat()
        writer_id = control_state["writer_fence"]["writer_id"]

        role_template = roles_state["roles"][0]
        product_head = self._git(product, "rev-parse", "HEAD")
        roles: list[dict[str, Any]] = []
        runs: list[dict[str, Any]] = []
        assignments: dict[str, Path] = {}
        for index, role_id in enumerate(("ROLE-A", "ROLE-B"), start=1):
            assignment_id = f"assign-broker-{index}"
            run_id = f"run-broker-{index}"
            session_id = f"session-broker-{index}"
            outbox_dir = (
                control / ".yefeng" / "outbox" / scope_id / role_id / run_id
            )
            inbox_dir = (
                control / ".yefeng" / "broker" / scope_id / "inbox" / role_id
            )
            role = copy.deepcopy(role_template)
            role.update(
                {
                    "role_id": role_id,
                    "role_name": f"Broker role {index}",
                    "state": "RUNNING",
                    "assigned_by": writer_id,
                    "assignment_id": assignment_id,
                    "session_id": session_id,
                    "process_id": 41000 + index,
                    "run_id": run_id,
                    "product_baseline_commit": product_head,
                    "product_worktree": str(product),
                    "current_checkpoint": "broker-contract",
                    "owned_scope": [f"module-{index}/**"],
                    "forbidden_scope": [".yefeng/series/**"],
                    "blocked_by": "",
                    "resume_when": "",
                    "required_evidence": "",
                    "wake_target": "",
                    "last_seen": datetime.now(timezone.utc).isoformat(),
                    "lease_expires_at": (
                        datetime.now(timezone.utc) + timedelta(hours=1)
                    ).isoformat(),
                    "last_output": "Ready to communicate through the broker.",
                }
            )
            roles.append(role)
            runs.append(
                {
                    "run_id": run_id,
                    "role_id": role_id,
                    "assignment_id": assignment_id,
                    "scope_id": scope_id,
                    "run_epoch": 1,
                    "control_repo_id": control_state["control_repo_id"],
                    "product_repo_id": role["product_repo_id"],
                    "product_baseline_commit": product_head,
                    "product_branch": "main",
                    "product_worktree": str(product),
                    "transport_mode": "control-spool",
                    "session_id": session_id,
                    "process_id": role["process_id"],
                    "command": "codex exec",
                    "cwd": str(product),
                    "started_at": datetime.now(timezone.utc).isoformat(),
                    "ended_at": "",
                    "exit_code": None,
                    "status": "RUNNING",
                }
            )
            assignment_path = (
                control
                / ".yefeng"
                / "runs"
                / scope_id
                / role_id
                / run_id
                / "assignment.json"
            )
            self._write_json(
                assignment_path,
                {
                    "version": 1,
                    "control_plane_mode": "external-git",
                    "control_repo_id": control_state["control_repo_id"],
                    "control_root": str(control),
                    "scope_id": scope_id,
                    "run_epoch": 1,
                    "assignment_id": assignment_id,
                    "run_id": run_id,
                    "role_id": role_id,
                    "assigned_by": writer_id,
                    "product_repo_id": role["product_repo_id"],
                    "product_root": str(product),
                    "product_worktree": str(product),
                    "product_baseline_commit": product_head,
                    "transport_mode": "control-spool",
                    "outbox_dir": str(outbox_dir),
                    "inbox_dir": str(inbox_dir),
                },
            )
            assignments[role_id] = assignment_path

        roles_state["roles"] = roles
        runs_state["runs"] = runs
        self._write_json(control_path, control_state)
        self._write_json(roles_path, roles_state)
        self._write_json(runs_path, runs_state)
        self._git(control, "add", "--all")
        self._git(control, "commit", "-m", "fixture: active broker roles")
        self.assertEqual(self._git(control, "status", "--short"), "")
        return control, product, scope_id, assignments

    def _control_script(self, name: str) -> Path:
        return self.control / "scripts" / "yefeng" / name

    def _publish(
        self,
        sender: str,
        message_type: str,
        recipient: str,
        summary: str,
        *extra: str,
        engine: str | None = None,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        return self._ps(
            self._control_script("publish-role-message.ps1"),
            "-AssignmentPath",
            str(self.assignments[sender]),
            "-Type",
            message_type,
            "-Recipient",
            recipient,
            "-Summary",
            summary,
            *extra,
            engine=engine,
            check=check,
        )

    def _broker_once(self, *, engine: str | None = None) -> dict[str, Any]:
        return self._json_output(
            self._ps(
                self._control_script("message-broker.ps1"),
                "-Mode",
                "Once",
                "-ControlRoot",
                str(self.control),
                "-ScopeId",
                self.scope_id,
                engine=engine,
            )
        )

    def _journal(self) -> list[dict[str, Any]]:
        path = (
            self.control
            / ".yefeng"
            / "broker"
            / self.scope_id
            / "journal"
            / "events.jsonl"
        )
        if not path.exists():
            return []
        return [
            json.loads(line)
            for line in path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]

    def test_publish_import_receive_and_runtime_git_isolation(self) -> None:
        published = self._json_output(
            self._publish(
                "ROLE-A",
                "QUESTION",
                "ROLE-B",
                "Which schema version should ROLE-A consume?",
                "-CorrelationId",
                "contract-schema-v1",
                "-Priority",
                "high",
            )
        )
        source_path = Path(published["message_path"])
        self.assertTrue(source_path.is_file())
        message = self._read_json(source_path)
        self.assertEqual(message["role_id"], "ROLE-A")
        self.assertEqual(message["recipient"], "ROLE-B")
        self.assertEqual(message["sender_sequence"], 1)

        result = self._broker_once()
        self.assertEqual(result["accepted"], 1)
        self.assertEqual(result["quarantined"], 0)
        self.assertFalse(source_path.exists())

        received = self._json_output(
            self._ps(
                self._control_script("receive-role-message.ps1"),
                "-AssignmentPath",
                str(self.assignments["ROLE-B"]),
            )
        )
        self.assertEqual(received["count"], 1)
        delivered = received["messages"][0]
        self.assertEqual(delivered["message"]["message_id"], published["message_id"])
        self.assertEqual(delivered["message"]["payload"]["summary"], message["payload"]["summary"])

        receipt = (
            self.control
            / ".yefeng"
            / "broker"
            / self.scope_id
            / "receipts"
            / "ROLE-A"
            / f"{published['message_id']}.json"
        )
        self.assertTrue(receipt.is_file())
        self.assertEqual(self._read_json(receipt)["status"], "accepted")
        self.assertEqual(
            self._git(self.control, "status", "--short"),
            "",
            "the runtime broker must not dirty tracked governance",
        )

    def test_level_one_gate_refuses_broker_and_publishers(self) -> None:
        control_path = (
            self.control
            / ".yefeng"
            / "series"
            / self.scope_id
            / "state"
            / "control.json"
        )
        control_state = self._read_json(control_path)
        control_state["startup_level"] = "LEVEL_1_GOVERNANCE_BOOTSTRAP"
        control_state["updated_at"] = datetime.now(timezone.utc).isoformat()
        self._write_json(control_path, control_state)

        start = self._ps(
            self._control_script("message-broker.ps1"),
            "-Mode",
            "Start",
            "-ControlRoot",
            str(self.control),
            "-ScopeId",
            self.scope_id,
            check=False,
        )
        self.assertNotEqual(start.returncode, 0)
        self.assertIn("LEVEL_3_FULL_PARALLEL_YEFENG", start.stderr)

        publish = self._publish(
            "ROLE-A",
            "PROGRESS",
            "ROLE-B",
            "must remain gated",
            check=False,
        )
        self.assertNotEqual(publish.returncode, 0)
        self.assertIn("LEVEL_3_FULL_PARALLEL_YEFENG", publish.stderr)

        process_state = (
            self.control
            / ".yefeng"
            / "broker"
            / self.scope_id
            / "process.json"
        )
        self.assertFalse(process_state.exists())

    def test_blocking_contract_and_assignment_path_escape_are_rejected(self) -> None:
        incomplete = self._publish(
            "ROLE-A",
            "BLOCKER",
            "ROLE-B",
            "Blocked on the reviewed schema.",
            "-Blocking",
            check=False,
        )
        self.assertNotEqual(incomplete.returncode, 0)
        self.assertIn("blocking", incomplete.stderr.lower())

        accepted = self._json_output(
            self._publish(
                "ROLE-A",
                "BLOCKER",
                "ROLE-B",
                "Blocked on the reviewed schema.",
                "-Blocking",
                "-BlockedRole",
                "ROLE-A",
                "-BlockedCheckpoint",
                "A1",
                "-BlockedBy",
                "ROLE-B schema contract",
                "-ResumeWhen",
                "ROLE-B publishes the reviewed contract",
                "-RequiredEvidence",
                "review passed",
                "-WakeTarget",
                "ROLE-A",
            )
        )
        self.assertTrue(Path(accepted["message_path"]).is_file())

        escaped_assignment = self.fixture_root / "escaped-assignment.json"
        assignment = self._read_json(self.assignments["ROLE-A"])
        assignment["outbox_dir"] = str(self.fixture_root / "outside-outbox")
        self._write_json(escaped_assignment, assignment)
        escaped = self._ps(
            self._control_script("publish-role-message.ps1"),
            "-AssignmentPath",
            str(escaped_assignment),
            "-Type",
            "PROGRESS",
            "-Recipient",
            "TOTAL_CONTROL",
            "-Summary",
            "This must not be written.",
            check=False,
        )
        self.assertNotEqual(escaped.returncode, 0)
        self.assertIn("outbox", escaped.stderr.lower())
        self.assertFalse((self.fixture_root / "outside-outbox").exists())

        oversized = self._publish(
            "ROLE-A",
            "PROGRESS",
            "TOTAL_CONTROL",
            "x" * 5000,
            check=False,
        )
        self.assertNotEqual(oversized.returncode, 0)
        self.assertIn("4096", oversized.stderr)

    def test_concurrent_publishers_serialize_sender_sequence(self) -> None:
        command_prefix = [
            POWERSHELL,
            "-NoLogo",
            "-NoProfile",
            "-File",
            str(self._control_script("publish-role-message.ps1")),
            "-AssignmentPath",
            str(self.assignments["ROLE-A"]),
            "-Type",
            "PROGRESS",
            "-Recipient",
            "TOTAL_CONTROL",
        ]
        processes = [
            subprocess.Popen(
                [*command_prefix, "-Summary", f"parallel progress {index}"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
            )
            for index in range(12)
        ]
        outputs: list[dict[str, Any]] = []
        for process in processes:
            stdout, stderr = process.communicate(timeout=30)
            self.assertEqual(process.returncode, 0, stderr)
            outputs.append(json.loads(stdout.lstrip("\ufeff").strip()))

        self.assertEqual(
            sorted(output["sender_sequence"] for output in outputs),
            list(range(1, 13)),
        )
        result = self._broker_once()
        self.assertEqual(result["accepted"], 12)
        accepted = [
            event for event in self._journal() if event["event_type"] == "MESSAGE_ACCEPTED"
        ]
        self.assertEqual(len(accepted), 12)
        self.assertEqual(len({event["message"]["message_id"] for event in accepted}), 12)

    def test_duplicate_replay_repairs_projections_and_conflict_is_quarantined(self) -> None:
        published = self._json_output(
            self._publish(
                "ROLE-A",
                "ANSWER",
                "ROLE-B",
                "Use schema version 3.",
                "-CorrelationId",
                "contract-schema-v1",
            )
        )
        source_path = Path(published["message_path"])
        source_bytes = source_path.read_bytes()
        first = self._broker_once()
        self.assertEqual(first["accepted"], 1)
        accepted_event = next(
            event for event in self._journal() if event["event_type"] == "MESSAGE_ACCEPTED"
        )
        inbox_path = Path(accepted_event["inbox_path"])
        receipt_path = Path(accepted_event["receipt_path"])
        inbox_path.unlink()
        receipt_path.unlink()
        source_path.parent.mkdir(parents=True, exist_ok=True)
        source_path.write_bytes(source_bytes)

        replay = self._broker_once()
        self.assertEqual(replay["duplicates"], 1)
        self.assertGreaterEqual(replay["repaired"], 2)
        self.assertTrue(inbox_path.is_file())
        self.assertTrue(receipt_path.is_file())
        self.assertEqual(
            len(
                [
                    event
                    for event in self._journal()
                    if event["event_type"] == "MESSAGE_ACCEPTED"
                ]
            ),
            1,
        )

        conflicting = json.loads(source_bytes.decode("utf-8"))
        conflicting["payload"]["summary"] = "Conflicting duplicate content."
        source_path.write_text(
            json.dumps(conflicting, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        conflict = self._broker_once()
        self.assertEqual(conflict["quarantined"], 1)
        self.assertFalse(source_path.exists())
        quarantine_files = list(
            (
                self.control / ".yefeng" / "quarantine" / self.scope_id
            ).glob("*.message.json")
        )
        self.assertEqual(len(quarantine_files), 1)

    def test_stale_epoch_is_quarantined_without_delivery(self) -> None:
        published = self._json_output(
            self._publish(
                "ROLE-A",
                "CHECKPOINT",
                "ROLE-B",
                "Checkpoint A2 completed.",
            )
        )
        source_path = Path(published["message_path"])
        stale = self._read_json(source_path)
        stale["run_epoch"] = 99
        self._write_json(source_path, stale)

        result = self._broker_once()
        self.assertEqual(result["accepted"], 0)
        self.assertEqual(result["quarantined"], 1)
        inbox_root = (
            self.control
            / ".yefeng"
            / "broker"
            / self.scope_id
            / "inbox"
            / "ROLE-B"
        )
        self.assertEqual(list(inbox_root.glob("*.json")) if inbox_root.exists() else [], [])
        quarantine_events = [
            event
            for event in self._journal()
            if event["event_type"] == "MESSAGE_QUARANTINED"
        ]
        self.assertEqual(len(quarantine_events), 1)
        self.assertIn("epoch", quarantine_events[0]["reason"].lower())

    def test_malformed_utf8_and_oversized_sources_are_quarantined(self) -> None:
        outbox = Path(self._read_json(self.assignments["ROLE-A"])["outbox_dir"])
        outbox.mkdir(parents=True, exist_ok=True)
        malformed = outbox / "msg-malformed-utf8.json"
        malformed.write_bytes(b"\xff\xfe\x00not-utf8")

        published = self._json_output(
            self._publish(
                "ROLE-A",
                "PROGRESS",
                "TOTAL_CONTROL",
                "This envelope will be made too large.",
            )
        )
        oversized = Path(published["message_path"])
        oversized.write_bytes(oversized.read_bytes() + b" " * (70 * 1024))

        result = self._broker_once()
        self.assertEqual(result["accepted"], 0)
        self.assertEqual(result["quarantined"], 2)
        self.assertFalse(malformed.exists())
        self.assertFalse(oversized.exists())
        quarantine_root = (
            self.control / ".yefeng" / "quarantine" / self.scope_id
        )
        self.assertEqual(len(list(quarantine_root.glob("*.message.json"))), 2)

    def test_background_start_delivery_status_and_cooperative_stop(self) -> None:
        broker = self._control_script("message-broker.ps1")
        started = self._json_output(
            self._ps(
                broker,
                "-Mode",
                "Start",
                "-ControlRoot",
                str(self.control),
                "-ScopeId",
                self.scope_id,
                "-PollIntervalMilliseconds",
                "100",
            )
        )
        self.assertTrue(started["running"])
        self.addCleanup(
            lambda: self._ps(
                broker,
                "-Mode",
                "Stop",
                "-ControlRoot",
                str(self.control),
                "-ScopeId",
                self.scope_id,
                check=False,
            )
        )
        second_start = self._json_output(
            self._ps(
                broker,
                "-Mode",
                "Start",
                "-ControlRoot",
                str(self.control),
                "-ScopeId",
                self.scope_id,
            )
        )
        self.assertTrue(second_start["already_running"])
        self.assertEqual(second_start["process_id"], started["process_id"])

        published = self._json_output(
            self._publish(
                "ROLE-A",
                "HANDOFF",
                "ROLE-B",
                "ROLE-A completed its assigned checkpoint.",
            )
        )
        receipt = (
            self.control
            / ".yefeng"
            / "broker"
            / self.scope_id
            / "receipts"
            / "ROLE-A"
            / f"{published['message_id']}.json"
        )
        deadline = time.monotonic() + 10
        while not receipt.exists() and time.monotonic() < deadline:
            time.sleep(0.1)
        self.assertTrue(receipt.is_file())

        status = self._json_output(
            self._ps(
                broker,
                "-Mode",
                "Status",
                "-ControlRoot",
                str(self.control),
                "-ScopeId",
                self.scope_id,
            )
        )
        self.assertTrue(status["running"])
        stopped = self._json_output(
            self._ps(
                broker,
                "-Mode",
                "Stop",
                "-ControlRoot",
                str(self.control),
                "-ScopeId",
                self.scope_id,
                "-StopTimeoutSeconds",
                "10",
            )
        )
        self.assertTrue(stopped["stopped"])
        final_status = self._json_output(
            self._ps(
                broker,
                "-Mode",
                "Status",
                "-ControlRoot",
                str(self.control),
                "-ScopeId",
                self.scope_id,
            )
        )
        self.assertFalse(final_status["running"])

    @unittest.skipUnless(
        WINDOWS_POWERSHELL is not None, "Windows PowerShell 5.1 is not available"
    )
    def test_message_flow_supports_windows_powershell_51(self) -> None:
        published = self._json_output(
            self._publish(
                "ROLE-A",
                "QUESTION",
                "ROLE-B",
                "PowerShell 5.1 transport check.",
                engine=WINDOWS_POWERSHELL,
            )
        )
        result = self._broker_once(engine=WINDOWS_POWERSHELL)
        self.assertEqual(result["accepted"], 1)
        received = self._json_output(
            self._ps(
                self._control_script("receive-role-message.ps1"),
                "-AssignmentPath",
                str(self.assignments["ROLE-B"]),
                engine=WINDOWS_POWERSHELL,
            )
        )
        self.assertEqual(received["count"], 1)
        self.assertEqual(
            received["messages"][0]["message"]["message_id"],
            published["message_id"],
        )


if __name__ == "__main__":
    unittest.main()
