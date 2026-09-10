"""Aggregation and renderer contracts, runnable with AWK independently of Bash."""

import csv
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET


SCRIPT = Path(__file__).resolve().parents[1] / "git-diff-helper.sh"
US = "\x1f"


def record(*fields):
    return US.join(map(str, fields)) + "\n"


class SelectedAggregationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.awk = os.environ.get("TEST_AWK", "awk")
        source = SCRIPT.read_text(encoding="utf-8")
        cls.programs = dict(re.findall(
            r'cat >"\$TMPD/(\w+)\.awk" <<\'AWKEOF\'\n(.*?)\nAWKEOF', source, re.S,
        ))

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="selected-aggregation-tests-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for name, program in self.programs.items():
            (self.root / f"{name}.awk").write_text(program, encoding="utf-8")

    def run_awk(self, name, data, inputs=(), **variables):
        command = [self.awk]
        for key, value in variables.items():
            command.extend(("-v", f"{key}={value}"))
        command.extend(("-f", str(self.root / f"{name}.awk")))
        command.extend(map(str, inputs))
        result = subprocess.run(command, input=data, capture_output=True, text=True,
                                encoding="utf-8", timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def aggregate(self, data):
        lines = self.root / "lines"
        lines.mkdir()
        return self.run_awk("selected", data, dir=lines.as_posix())

    def records(self, output, kind):
        return [line.split(US) for line in output.split("\n") if line.startswith(kind + US)]

    def commit(self, number):
        sha = str(number) * 40
        return (record("SELECT", sha, "parent" + str(number))
                + record("COMMIT", sha, "2026-01-01", "Author", "日本語 < & |"))

    def file(self, number, path, status="M", adds=1, deletes=0, binary=0, old=None):
        return record("FILE", number, status[0], status, adds, deletes,
                      path if old is None else old, path, binary, "")

    def line(self, number, text, kind="add", old="", new=1):
        return record("LINE", number, 1, old, new, kind, text)

    def sample(self):
        return (self.commit(1)
                + self.file(1, "共通 file.txt", "A", adds=2)
                + self.file(2, "other.txt", adds=1)
                + self.line(1, "before") + self.line(2, "other")
                + self.commit(2)
                + self.file(1, "共通 file.txt", adds=1, deletes=1)
                + self.line(1, "before", "del", old=1, new="")
                + self.line(1, 'after < & " |\t\\value', new=7))

    def test_same_path_is_counted_once_and_line_totals_are_summed(self):
        output = self.aggregate(self.sample())
        files = self.records(output, "FILE")
        self.assertEqual(len(files), 2)
        self.assertEqual(files[0][2:6], ["M", "A/M", "3", "1"])
        self.assertEqual(files[0][7], "共通 file.txt")
        self.assertEqual(files[1][7], "other.txt")

    def test_details_are_grouped_by_file_and_keep_commit_order_and_line_numbers(self):
        output = self.aggregate(self.sample())
        lines = self.records(output, "LINE")
        self.assertEqual([row[1] for row in lines], ["1"] * 5 + ["2"] * 2)
        markers = [row[6] for row in lines if row[5] == "meta"]
        self.assertIn("コミット: " + "1" * 40, markers[0])
        self.assertIn("コミット: " + "2" * 40, markers[1])
        self.assertIn("状態: A", markers[0])
        self.assertIn("状態: M", markers[1])
        self.assertEqual(lines[3][3:5], ["1", ""])
        self.assertEqual(lines[4][3:5], ["", "7"])
        self.assertEqual(lines[4][6], 'after < & " |\t\\value')

    def test_addition_and_deletion_are_not_cancelled(self):
        data = (self.commit(1) + self.file(1, "file", "A") + self.line(1, "added")
                + self.commit(2) + self.file(1, "file", "D", adds=0, deletes=1)
                + self.line(1, "added", "del", old=1, new=""))
        output = self.aggregate(data)
        self.assertEqual(self.records(output, "FILE")[0][2:6], ["M", "A/D", "1", "1"])
        self.assertEqual([row[5] for row in self.records(output, "LINE")],
                         ["meta", "add", "meta", "del"])

    def test_rename_uses_destination_path_and_retains_original_details(self):
        data = (self.commit(1) + self.file(1, "new.txt", "R100", adds=0, old="old.txt")
                + self.line(1, "rename from old.txt", "meta", new="")
                + self.line(1, "rename to new.txt", "meta", new="")
                + self.commit(2) + self.file(1, "new.txt") + self.line(1, "content"))
        output = self.aggregate(data)
        files = self.records(output, "FILE")
        self.assertEqual(len(files), 1)
        self.assertEqual(files[0][2:4], ["M", "R100/M"])
        self.assertEqual(files[0][6:8], ["new.txt", "new.txt"])
        self.assertIn("rename from old.txt", output)

    def test_binary_marker_is_retained_alongside_text_changes(self):
        data = (self.commit(1) + self.file(1, "file", adds=0, binary=1)
                + self.line(1, "Binary files differ", "bin", new="")
                + self.commit(2) + self.file(1, "file") + self.line(1, "text"))
        output = self.aggregate(data)
        self.assertEqual(self.records(output, "FILE")[0][4:9],
                         ["1", "0", "file", "file", "1"])

    def test_empty_commits_remain_in_history_with_no_files(self):
        output = self.aggregate(self.commit(1) + self.commit(2))
        self.assertEqual(len(self.records(output, "COMMIT")), 2)
        self.assertEqual(self.records(output, "FILE"), [])
        self.assertEqual(self.records(output, "LINE"), [])

    def test_many_files_and_similar_numeric_paths_do_not_collide(self):
        names = ["0", "00", "01", "1", "1e0"] + [f"file-{i}" for i in range(300)]
        data = self.commit(1)
        data += "".join(self.file(i, name) for i, name in enumerate(names, 1))
        data += "".join(self.line(i, name) for i, name in enumerate(names, 1))
        output = self.aggregate(data)
        self.assertEqual([row[7] for row in self.records(output, "FILE")], names)
        self.assertEqual(len(self.records(output, "LINE")), 2 * len(names))

    def test_actual_git_diffs_include_only_selected_commits(self):
        repo = self.root / "repository with spaces"
        repo.mkdir()
        env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                   GIT_TERMINAL_PROMPT="0")

        def git(*args):
            result = subprocess.run(
                ["git", "-C", str(repo), "-c", "user.name=Test Author", "-c",
                 "user.email=test@example.invalid", "-c", "commit.gpgSign=false",
                 "-c", "core.autocrlf=false", "-c", "core.quotepath=false", *args],
                input="", capture_output=True, text=True, encoding="utf-8", env=env, timeout=20,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout

        git("init", "-q", "-b", "main")
        common = repo / "common file.txt"
        common.write_bytes(b"start\n")
        git("add", "--", ".")
        git("commit", "-qm", "initial")
        first = git("rev-parse", "HEAD").strip()
        common.write_bytes(b"middle\n")
        (repo / "skipped-only.txt").write_bytes(b"skip this\n")
        git("add", "--", ".")
        git("commit", "-qm", "unselected")
        common.write_bytes(b"finish\n")
        (repo / "追加.txt").write_bytes(b"new file\n")
        git("add", "--", ".")
        git("commit", "-qm", "selected")
        last = git("rev-parse", "HEAD").strip()
        parents = [git("hash-object", "-t", "tree", "--stdin").strip(),
                   git("rev-parse", "HEAD^1").strip()]
        data = ""
        for commit, parent in zip((first, last), parents):
            data += record("SELECT", commit, parent)
            data += record("COMMIT", commit, "2026-01-01", "Author", "subject")
            paths = []
            for option in ("--name-status", "--numstat"):
                path = self.root / f"{option[2:]}.txt"
                text = git("diff", "-M", option, "-z", parent, commit, "--")
                path.write_bytes(text.replace("\0", "\n").encode("utf-8"))
                paths.append(path)
            data += self.run_awk("files", "", inputs=paths)
            patch = git("diff", "--no-ext-diff", "--no-color", "-M", "-U0", parent, commit, "--")
            data += self.run_awk("patch", patch)
        output = self.aggregate(data)
        files = self.records(output, "FILE")
        self.assertEqual([row[7] for row in files], ["common file.txt", "追加.txt"])
        self.assertEqual(files[0][2:6], ["M", "A/M", "2", "1"])
        self.assertEqual([row[6] for row in self.records(output, "LINE") if row[5] == "add"],
                         ["start", "finish", "new file"])
        self.assertEqual([row[1] for row in self.records(output, "COMMIT")], [first, last])

    def test_aggregate_is_compatible_with_all_report_renderers(self):
        output = self.aggregate(self.sample())
        screen = self.run_awk("render", output, ascii=1, width=88)
        self.assertIn("コミット: " + "2" * 40, screen)
        self.assertIn("[1/2] 共通 file.txt", screen)
        markdown = self.run_awk("md", output, linenos=1)
        self.assertEqual(len(re.findall(r"^### \[\d+/2\]", markdown, re.M)), 2)
        self.assertIn("コミット: " + "2" * 40, markdown)
        self.run_awk("csv", output, out=(self.root / "report").as_posix())
        with next(self.root.glob("*_2_*.csv")).open(encoding="utf-8-sig", newline="") as stream:
            rows = list(csv.reader(stream))
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[1][3:6], ["3", "1", "4"])
        xlsx = self.root / "xlsx"
        (xlsx / "xl" / "worksheets").mkdir(parents=True)
        self.run_awk("xlsx", output, out=xlsx.as_posix(), maxrows=100000)
        sheets = sorted((xlsx / "xl" / "worksheets").glob("*.rows"))
        self.assertEqual(len(sheets), 4)
        for sheet in sheets:
            ET.fromstring("<root>" + sheet.read_text(encoding="utf-8") + "</root>")


if __name__ == "__main__":
    unittest.main()
