"""CLI integration tests using disposable Git repositories and real Bash."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import unittest
import xml.etree.ElementTree as ET
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "git-diff-helper.sh"


class GitDiffHelperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bash = os.environ.get("TEST_BASH", "bash")
        probe = subprocess.run(
            [cls.bash, "--version"], capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=15,
        )
        if probe.returncode:
            raise RuntimeError(f"Bash cannot run: {probe.stderr.strip()}")
        cls.temp = tempfile.TemporaryDirectory(prefix="git-diff-helper-tests-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root = Path(cls.temp.name)
        cls.env = {key: value for key, value in os.environ.items()
                   if not key.startswith("GIT_")}
        cls.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                       GIT_TERMINAL_PROMPT="0", LC_ALL="C.UTF-8", TERM="dumb")
        cls.repo = cls.root / "repository with spaces"
        cls.commits = cls.make_repo(cls.repo, "main", 23)
        for branch, index in (("single", 0), ("two", 1), ("ten", 9), ("eleven", 10),
                              ("moving", 22), ("123", 1), ("origin/topic", 1)):
            cls.git("branch", branch, cls.commits[index])
        cls.git("tag", "main", cls.commits[0])
        cls.git("update-ref", "refs/remotes/origin/main", cls.commits[-1])
        cls.git("update-ref", "refs/remotes/origin/topic", cls.commits[-1])
        cls.git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
        cls.git("checkout", "-q", "-b", "feature/topic", cls.commits[18])
        (cls.repo / "feature-only.txt").write_text("feature\n", encoding="utf-8")
        cls.git("add", "--", "feature-only.txt")
        cls.git("commit", "-qm", "feature side")
        cls.git("merge", "--no-ff", "-m", "merge main into feature", "refs/heads/main")
        (cls.repo / "tracked file.txt").write_text("unstaged\n", encoding="utf-8")
        (cls.repo / "other.txt").write_text("staged\n", encoding="utf-8")
        cls.git("add", "--", "other.txt")
        (cls.repo / "untracked.txt").write_text("untracked\n", encoding="utf-8")
        cls.empty = cls.root / "empty"
        cls.make_repo(cls.empty, "main", 0)
        cls.no_main = cls.root / "no main"
        cls.make_repo(cls.no_main, "develop", 2)

    @classmethod
    def git(cls, *args, repo=None):
        result = subprocess.run(
            ["git", "-C", str(repo or cls.repo), *args], env=cls.env,
            capture_output=True, text=True, encoding="utf-8", timeout=20,
        )
        if result.returncode:
            raise AssertionError(f"git {args}: {result.stderr}")
        return result.stdout

    @classmethod
    def make_repo(cls, path, branch, count):
        path.mkdir()
        cls.git("init", "-q", "-b", branch, repo=path)
        for name, value in (("user.name", "Test Author"),
                            ("user.email", "test@example.invalid"),
                            ("commit.gpgSign", "false"), ("core.autocrlf", "false")):
            cls.git("config", name, value, repo=path)
        commits = []
        for number in range(1, count + 1):
            (path / "tracked file.txt").write_text(
                "".join(f"line {i:02d}\n" for i in range(1, number + 1)), encoding="utf-8",
            )
            (path / "other.txt").write_text(f"other {number}\n", encoding="utf-8")
            cls.git("add", "--", "tracked file.txt", "other.txt", repo=path)
            subject = f"commit {number:02d} 日本語 | < &"
            if number == 23:
                subject += "\tcontrol\x1b[31m"
            cls.git("commit", "-qm", subject, repo=path)
            commits.append(cls.git("rev-parse", "HEAD", repo=path).strip())
        return commits

    def setUp(self):
        self.output = self.root / self.id().rsplit(".", 1)[-1]

    def command(self, *args, repo=None):
        return [self.bash, SCRIPT.as_posix(), "-r", (repo or self.repo).as_posix(),
                "-o", self.output.as_posix(), "--no-color", "--ascii", "--no-md",
                "--no-excel", "--no-manual", *args]

    def run_helper(self, input_text, *args, repo=None):
        return subprocess.run(
            self.command(*args, repo=repo), input=input_text, env=self.env,
            capture_output=True, text=True, encoding="utf-8", timeout=30,
        )

    def assert_diff(self, result, before, after, paths=()):
        self.assertEqual(result.returncode, 0, result.stderr)
        files = list(self.output.glob("*.txt"))
        self.assertEqual(len(files), 1)
        report = files[0].read_text(encoding="utf-8")
        raw = report.split(" 【参考】生の git diff 出力\n", 1)[1].split("\n", 2)[2]
        expected = self.git("diff", "--no-ext-diff", "--no-color", "-M", "-U3",
                            before, after, "--", *paths)
        self.assertEqual(raw, expected or "(差分なし)\n")
        self.assertIn(before, report)
        self.assertIn(after, report)
        self.assertNotIn("[ ブランチ選択 ]", result.stdout)
        return report

    def pages(self, stderr):
        blocks = re.findall(
            r"\[ 比較(?:元|先) \([^\n]+\) \][^\n]*\n(.*?)  番号: 選択", stderr, re.S,
        )
        return [re.findall(r"^\s+\d+\) ([0-9a-f]+)  ", block, re.M) for block in blocks]

    def test_default_main_ignores_head_and_same_named_tag(self):
        result = self.run_helper("\n2\n1\n", "-m", "interactive")
        report = self.assert_diff(result, self.commits[-2], self.commits[-1])
        self.assertIn("refs/heads/main", report)
        self.assertEqual([len(page) for page in self.pages(result.stderr)], [10, 10])
        self.assertEqual(self.pages(result.stderr)[0],
                         [self.git("rev-parse", "--short", sha).strip()
                          for sha in reversed(self.commits[-10:])])

    def test_branch_number_and_mode_alias(self):
        refs = self.git("for-each-ref", "--sort=refname", "--format=%(refname)%09%(symref)",
                        "refs/heads/", "refs/remotes/").splitlines()
        names = [line.split("\t")[0] for line in refs if not line.split("\t")[1]]
        number = names.index("refs/heads/main") + 1
        result = self.run_helper(f"{number}\n2\n1\n", "select")
        self.assert_diff(result, self.commits[-2], self.commits[-1])

    def test_override_default_branch(self):
        result = self.run_helper("\n2\n1\n", "-m", "interactive", "-b", "two")
        self.assert_diff(result, self.commits[0], self.commits[1])

    def test_remote_branch_and_symbolic_head_exclusion(self):
        result = self.run_helper("origin/main\n2\n1\n", "-m", "interactive")
        self.assert_diff(result, self.commits[-2], self.commits[-1])
        self.assertNotIn("origin/HEAD", result.stderr)

    def test_full_ref_disambiguates_numeric_and_remote_names(self):
        for ref, expected in (("refs/heads/123", self.commits[:2]),
                              ("refs/heads/origin/topic", self.commits[:2]),
                              ("refs/remotes/origin/topic", self.commits[-2:])):
            with self.subTest(ref=ref):
                result = self.run_helper(f"{ref}\n2\n1\n", "-m", "interactive")
                self.assert_diff(result, *expected)
                for path in self.output.glob("*.txt"):
                    path.unlink()

    def test_forward_backward_and_reverse_diff(self):
        result = self.run_helper("\nn\np\n10\nn\n1\n", "-m", "interactive")
        self.assert_diff(result, self.commits[13], self.commits[12])
        self.assertEqual([len(page) for page in self.pages(result.stderr)], [10] * 5)

    def test_last_partial_page_and_boundaries(self):
        result = self.run_helper("\np\nn\nn\nn\n3\n1\n", "-m", "interactive")
        self.assert_diff(result, self.commits[0], self.commits[-1])
        self.assertIn("最初のページ", result.stderr)
        self.assertIn("最後のページ", result.stderr)
        self.assertEqual([len(page) for page in self.pages(result.stderr)],
                         [10, 10, 10, 3, 3, 10])

    def test_exactly_ten_commits_has_no_next_page(self):
        result = self.run_helper("ten\nn\n10\n1\n", "-m", "interactive")
        self.assert_diff(result, self.commits[0], self.commits[9])
        self.assertIn("最後のページ", result.stderr)
        self.assertEqual([len(page) for page in self.pages(result.stderr)], [10, 10, 10])

    def test_eleven_commits_has_one_item_on_second_page(self):
        result = self.run_helper("eleven\nn\n2\n1\n1\n", "-m", "interactive")
        self.assert_diff(result, self.commits[0], self.commits[10])
        self.assertEqual([len(page) for page in self.pages(result.stderr)], [10, 1, 1, 10])

    def test_invalid_input_and_same_commit_retry(self):
        result = self.run_helper(
            "missing\n\n0\n-1\n01\n999999999999999999999999\n1+1\n\n2\n2\n1\n",
            "-m", "interactive",
        )
        self.assert_diff(result, self.commits[-2], self.commits[-1])
        self.assertIn("ブランチが見つかりません", result.stderr)
        self.assertIn("比較元と異なるコミット", result.stderr)

    def test_missing_main_can_select_another_branch(self):
        result = self.run_helper("\ndevelop\n2\n1\n", "-m", "interactive", repo=self.no_main)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ブランチが見つかりません: main", result.stderr)
        self.assertIn("refs/heads/develop", result.stdout)

    def test_empty_and_single_commit_repositories(self):
        for repo, input_text, message in ((self.empty, "", "選択できるブランチがありません"),
                                          (self.repo, "single\n", "2件以上")):
            with self.subTest(repo=repo):
                result = self.run_helper(input_text, "-m", "interactive", repo=repo)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(message, result.stderr)
                self.assertFalse(self.output.exists())

    def test_cancel_at_every_step_creates_no_report(self):
        for input_text in ("q\n", "\nq\n", "\n2\nQ\n"):
            with self.subTest(input=input_text):
                result = self.run_helper(input_text, "-m", "interactive")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertFalse(self.output.exists())

    def test_eof_at_every_step_is_an_error(self):
        for input_text in ("", "\n", "\n2\n"):
            with self.subTest(input=input_text):
                result = self.run_helper(input_text, "-m", "interactive")
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("選択入力が終了しました", result.stderr)
                self.assertFalse(self.output.exists())

    def test_conflicting_options_fail_before_selection(self):
        for args in (("-f", "HEAD"), ("-t", "HEAD"), ("--merge-base",)):
            with self.subTest(args=args):
                result = self.run_helper("", "-m", "interactive", *args)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertNotIn("[ ブランチ選択 ]", result.stderr)

    def test_branch_option_validation(self):
        for args in (("-m", "commits", "-f", "HEAD", "-b", "main"),
                     ("-m", "interactive", "--branch"),
                     ("-m", "interactive", "--branch", "")):
            with self.subTest(args=args):
                result = self.run_helper("", *args)
                self.assertEqual(result.returncode, 1, result.stderr)

    def test_pathspec_filters_diff_but_not_history(self):
        result = self.run_helper("\n2\n1\n", "-m", "interactive", "--", "tracked file.txt")
        self.assert_diff(result, self.commits[-2], self.commits[-1], ("tracked file.txt",))
        self.assertEqual(len(self.pages(result.stderr)[0]), 10)
        self.assertNotIn("other.txt", result.stdout)

    def test_merge_history_includes_all_reachable_commits(self):
        result = self.run_helper("feature/topic\nn\nn\nq\n", "-m", "interactive")
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = [sha for page in self.pages(result.stderr) for sha in page]
        expected = self.git("log", "--date-order", "--format=%h", "refs/heads/feature/topic").splitlines()
        self.assertEqual(actual, expected)
        self.assertEqual(len(actual), 25)

    def test_control_characters_are_removed_from_menu(self):
        result = self.run_helper("\nq\n", "-m", "interactive")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("日本語", result.stderr)
        self.assertIn("control", result.stderr)
        self.assertNotIn("\x1b", result.stderr)
        self.assertNotIn("\t", result.stderr)

    def test_worktree_index_and_head_are_unchanged(self):
        commands = (("symbolic-ref", "HEAD"), ("status", "--porcelain=v1", "-z"),
                    ("diff", "--binary"), ("diff", "--cached", "--binary"),
                    ("for-each-ref", "--format=%(refname) %(objectname)"))
        before = [self.git(*args) for args in commands]
        result = self.run_helper("\n2\n1\n", "-m", "interactive")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([self.git(*args) for args in commands], before)

    def test_branch_tip_is_frozen_at_menu_creation(self):
        process = subprocess.Popen(
            self.command("-m", "interactive"), env=self.env, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8",
        )
        timer = threading.Timer(30, process.kill)
        timer.start()
        try:
            prefix = ""
            while not prefix.endswith("(q: 中止): "):
                character = process.stderr.read(1)
                self.assertTrue(character, prefix)
                prefix += character
            self.git("update-ref", "refs/heads/moving", self.commits[0])
            stdout, stderr = process.communicate("moving\n2\n1\n", timeout=20)
            result = subprocess.CompletedProcess(process.args, process.returncode, stdout, prefix + stderr)
            self.assert_diff(result, self.commits[-2], self.commits[-1])
        finally:
            timer.cancel()
            if process.poll() is None:
                process.kill()
            process.communicate()
            self.git("update-ref", "refs/heads/moving", self.commits[-1])

    def test_existing_explicit_commits_and_default_head(self):
        result = self.run_helper("", "-m", "commits", "-f", self.commits[0])
        self.assert_diff(result, self.commits[0], "HEAD")
        self.assertNotIn("[ ブランチ選択 ]", result.stderr)

    def test_existing_modes_still_run_without_input(self):
        for args in (("worktree",), ("staged",), ("head",), ("prev",),
                     ("commit", "-f", self.commits[0]),
                     ("branches", "-f", "refs/heads/main", "-t", "feature/topic"),
                     ("remote", "-t", "origin/main")):
            with self.subTest(mode=args[0]):
                result = self.run_helper("", "-m", *args, "--no-text")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Git 差分レポート", result.stdout)
                self.assertNotIn("[ ブランチ選択 ]", result.stderr)

    def test_markdown_and_csv_outputs(self):
        command = [arg for arg in self.command("-m", "interactive", "-x", "csv")
                   if arg not in ("--no-md", "--no-excel")]
        result = subprocess.run(command, input="\n2\n1\n", env=self.env,
                                capture_output=True, text=True, encoding="utf-8", timeout=30)
        self.assert_diff(result, self.commits[-2], self.commits[-1])
        markdown = list(self.output.glob("*.md"))
        self.assertEqual(len(markdown), 1)
        self.assertIn("refs/heads/main", markdown[0].read_text(encoding="utf-8"))
        csv_files = list(self.output.glob("*.csv"))
        self.assertEqual(len(csv_files), 4)
        self.assertTrue(all(path.stat().st_size > 0 for path in csv_files))

    def test_xlsx_report_and_updated_manual(self):
        command = [arg for arg in self.command("-m", "interactive", "-x", "xlsx", "--manual")
                   if arg not in ("--no-excel", "--no-manual")]
        result = subprocess.run(command, input="\n2\n1\n", env=self.env,
                                capture_output=True, text=True, encoding="utf-8", timeout=60)
        self.assert_diff(result, self.commits[-2], self.commits[-1])
        workbooks = list(self.output.glob("*.xlsx"))
        self.assertEqual(len(workbooks), 2, result.stderr)
        for path in workbooks:
            with self.subTest(file=path.name), zipfile.ZipFile(path) as archive:
                sheets = [name for name in archive.namelist()
                          if re.fullmatch(r"xl/worksheets/sheet\d+\.xml", name)]
                manual = "使い方ガイド" in path.name
                self.assertEqual(len(sheets), 9 if manual else 4)
                for name in archive.namelist():
                    if name.endswith((".xml", ".rels")):
                        ET.fromstring(archive.read(name))
                if manual:
                    self.assertIn("interactive", archive.read("xl/worksheets/sheet3.xml").decode())
                    self.assertIn("--branch", archive.read("xl/worksheets/sheet4.xml").decode())
                else:
                    self.assertIn("refs/heads/main", archive.read("xl/worksheets/sheet1.xml").decode())


if __name__ == "__main__":
    unittest.main()
