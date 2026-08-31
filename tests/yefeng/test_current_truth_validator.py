from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
VALIDATOR = (
    REPOSITORY_ROOT / "skills" / "yefeng" / "scripts" / "validate-current-truth.ps1"
)


def powershell() -> str:
    for executable in ("pwsh", "powershell"):
        resolved = shutil.which(executable)
        if resolved:
            return resolved
    raise unittest.SkipTest("PowerShell is unavailable")


def run_validator(registry: Path, archive_index: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            powershell(),
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(VALIDATOR),
            "-RegistryPath",
            str(registry),
            "-ArchiveIndexPath",
            str(archive_index),
        ],
        cwd=REPOSITORY_ROOT,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8-sig",
    )


class CurrentTruthValidatorTests(unittest.TestCase):
    def test_accepts_bounded_hot_view_with_resolvable_archive_index(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "archive" / "index.md"
            archive.parent.mkdir()
            archive.write_text("# Archive\n", encoding="utf-8")
            registry = root / "NEXT_STEPS.md"
            registry.write_text(
                "# Current truth\n\n"
                "Archive: [index](archive/index.md)\n\n"
                "| ID | State | Next |\n"
                "| --- | --- | --- |\n"
                "| CP-1 | implementation | validate |\n"
                "| CP-0 | closed | [evidence](archive/index.md) |\n",
                encoding="utf-8",
            )

            completed = run_validator(registry, archive)

            self.assertEqual(completed.returncode, 0, completed.stderr or completed.stdout)
            result = json.loads(completed.stdout)
            self.assertTrue(result["valid"])
            self.assertEqual(result["metrics"]["active_rows"], 1)
            self.assertEqual(result["metrics"]["terminal_rows"], 1)

    def test_rejects_bloat_fused_rows_duplicates_and_missing_links(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "archive" / "index.md"
            archive.parent.mkdir()
            archive.write_text("# Archive\n", encoding="utf-8")
            registry = root / "NEXT_STEPS.md"
            registry.write_text(
                "# Current truth\n\n"
                "| ID | State | Next |\n"
                "| --- | --- | --- |\n"
                "| CP-1 | implementation | [missing](missing.md) |\n"
                "| CP-1 | review | duplicate |\n"
                "| CP-2 | running | active |\n"
                "| CP-3 | validation | active |\n"
                "| CP-4 | closed | old || CP-5 | merged | old |\n",
                encoding="utf-8",
            )

            completed = run_validator(registry, archive)

            self.assertEqual(completed.returncode, 2, completed.stderr or completed.stdout)
            result = json.loads(completed.stdout)
            codes = {issue["code"] for issue in result["issues"]}
            self.assertIn("registry_duplicate_id", codes)
            self.assertIn("registry_fused_rows", codes)
            self.assertIn("registry_local_link_missing", codes)
            self.assertIn("registry_too_many_active_rows", codes)
            self.assertIn("archive_index_unlinked", codes)


if __name__ == "__main__":
    unittest.main()
