"""CLI integration tests using disposable Git repositories and real Bash."""

import csv
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
                    self.assertIn("multi", archive.read("xl/worksheets/sheet3.xml").decode())
                    self.assertIn("--branch", archive.read("xl/worksheets/sheet4.xml").decode())
                    self.assertIn("--commit", archive.read("xl/worksheets/sheet4.xml").decode())
                else:
                    self.assertIn("refs/heads/main", archive.read("xl/worksheets/sheet1.xml").decode())

    def assert_selected_diff(self, result, commits, paths=(), repo=None, diff_options=()):
        self.assertEqual(result.returncode, 0, result.stderr)
        reports = list(self.output.glob("*.txt"))
        self.assertEqual(len(reports), 1)
        report = reports[0].read_text(encoding="utf-8")
        raw = report.split(" 【参考】生の git diff 出力\n", 1)[1].split("\n", 2)[2]
        expected = []
        for commit in commits:
            parents = self.git("cat-file", "-p", commit, repo=repo).split("\n\n", 1)[0]
            parents = re.findall(r"^parent (\w+)$", parents, re.M)
            parent = parents[0] if parents else "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
            expected.append(f"# commit: {commit}\n# parent: {parent}\n")
            expected.append(self.git("-c", "core.quotepath=false", "diff", "--no-ext-diff",
                                     "--no-color", "-M", "-U3", *diff_options, parent,
                                     commit, "--", *paths, repo=repo))
        self.assertEqual(raw, "".join(expected))
        history = report.split("[ 対象コミット一覧 ]", 1)[1].split("[ 差分明細 ]", 1)[0]
        self.assertEqual(re.findall(r"^\s+([0-9a-f]{40})\s", history, re.M), commits)
        self.assertNotIn("[ 複数コミット選択 ]", result.stdout)
        return report

    def read_csv_sheet(self, sheet):
        paths = list(self.output.glob(f"*_{sheet}.csv"))
        self.assertEqual(len(paths), 1)
        with paths[0].open(encoding="utf-8-sig", newline="") as stream:
            return list(csv.reader(stream))

    def test_multi_nonadjacent_commits_aggregate_files_and_exclude_skipped_changes(self):
        selected = [self.commits[20], self.commits[22]]
        command = [arg for arg in self.command("-m", "multi", "-c", selected[0], "-c",
                                               selected[1], "-x", "csv", "--", "tracked file.txt")
                   if arg != "--no-excel"]
        result = subprocess.run(command, input="", env=self.env, capture_output=True,
                                text=True, encoding="utf-8", timeout=30)
        report = self.assert_selected_diff(result, selected, ("tracked file.txt",))
        self.assertNotIn("+line 22\n", report)
        self.assertIn("+line 21\n", report)
        self.assertIn("+line 23\n", report)
        files = self.read_csv_sheet("ファイル一覧")
        self.assertEqual(len(files), 2)
        self.assertEqual(files[1][3:6], ["2", "0", "2"])
        details = self.read_csv_sheet("差分明細")
        self.assertTrue(all(row[1] == "1" for row in details[1:]))
        self.assertEqual([row[5] for row in details[1:] if row[7] == "+"], ["21", "23"])

    def test_multi_interactive_toggle_duplicates_and_cross_page_selection(self):
        result = self.run_helper("\n1,3,3\nn\n1\np\n3\nd\n", "multi-select")
        self.assert_selected_diff(result, [self.commits[22], self.commits[12]])
        self.assertIn("[x]", result.stderr)
        self.assertIn("選択済み: 3 件", result.stderr)
        self.assertIn("refs/heads/main", result.stdout)

    def test_multi_invalid_numbers_do_not_partially_change_selection(self):
        result = self.run_helper(
            "\nd\n1 99\n01\n1+1\n999999999999999999999\n\np\n1 3\nd\n",
            "-m", "multi",
        )
        self.assert_selected_diff(result, [self.commits[22], self.commits[20]])
        self.assertIn("1件以上", result.stderr)
        self.assertIn("最初のページ", result.stderr)

    def test_multi_last_page_and_root_commit(self):
        result = self.run_helper("\nn\nn\nn\n3\nd\n", "-m", "multi")
        self.assert_selected_diff(result, [self.commits[0]])
        self.assertIn("最後のページ", result.stderr)
        self.assertIn("new file mode", result.stdout)

    def test_multi_single_commit_branch_and_empty_repository(self):
        result = self.run_helper("\n1\nd\n", "-m", "multi", "-b", "single")
        self.assert_selected_diff(result, [self.commits[0]])
        result = self.run_helper("", "-m", "multi", repo=self.empty)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("選択できるブランチがありません", result.stderr)

    def test_multi_empty_selection_cancel_and_eof_create_no_report(self):
        for input_text in ("q\n", "\nq\n", "\n1\nq\n", "\n1\n1\nd\nq\n",
                           "", "\n", "\n1\n"):
            with self.subTest(input=input_text):
                result = self.run_helper(input_text, "-m", "multi")
                self.assertEqual(result.returncode, 0 if "q" in input_text else 1, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertFalse(self.output.exists())

    def test_multi_explicit_refs_deduplicate_and_preserve_order(self):
        result = self.run_helper("", "-m", "multi", "-c", "refs/heads/main", "--commit",
                                 self.commits[-1][:12], "-c", self.commits[0], "-c", "refs/tags/main")
        self.assert_selected_diff(result, [self.commits[-1], self.commits[0]])
        self.assertNotIn("[ ブランチ選択 ]", result.stderr)

    def test_multi_option_errors_happen_before_selection_or_output(self):
        for args in (("-m", "multi", "-f", "HEAD"), ("-m", "multi", "-t", "HEAD"),
                     ("-m", "multi", "--merge-base"), ("-m", "multi", "--commit"),
                     ("-m", "multi", "-c", ""), ("-m", "multi", "-c", "missing"),
                     ("-m", "multi", "-c", "--all"),
                     ("-m", "multi", "-c", "HEAD", "-b", "main"),
                     ("-m", "multi", "-c", "HEAD", "-c", "missing"),
                     ("-m", "head", "-c", "HEAD")):
            with self.subTest(args=args):
                result = self.run_helper("", *args)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertNotIn("[ ブランチ選択 ]", result.stderr)
                self.assertFalse(self.output.exists())

    def test_multi_merge_uses_first_parent_and_only_selected_history(self):
        merge = self.git("rev-parse", "HEAD").strip()
        result = self.run_helper("", "-m", "multi", "-c", merge)
        self.assert_selected_diff(result, [merge])

    def test_multi_no_matching_paths_still_lists_selected_commits(self):
        result = self.run_helper("", "-m", "multi", "-c", self.commits[5], "-c",
                                 self.commits[9], "--", "missing-path/")
        self.assert_selected_diff(result, [self.commits[5], self.commits[9]], ("missing-path/",))
        self.assertIn("差分はありません", result.stdout)

    def test_multi_diff_options_and_file_display_limit(self):
        selected = [self.commits[20], self.commits[22]]
        options = ("--no-renames", "-w")
        result = self.run_helper("", "-m", "multi", "-c", selected[0], "-c", selected[1],
                                 *options, "-U", "0", "--max-lines", "2", "--", "tracked file.txt")
        self.assert_selected_diff(result, selected, ("tracked file.txt",),
                                  diff_options=(*options, "-U0"))
        self.assertIn("表示上限 (2 行)", result.stdout)

    def test_multi_rename_binary_delete_and_revert_remain_visible(self):
        repo = self.root / "multi file changes"
        self.make_repo(repo, "main", 1)
        path = repo / "追加 ファイル.txt"
        path.write_text("original\n", encoding="utf-8")
        (repo / "binary.dat").write_bytes(b"\0original")
        self.git("add", "--", ".", repo=repo)
        self.git("commit", "-qm", "add files", repo=repo)
        added = self.git("rev-parse", "HEAD", repo=repo).strip()
        path.write_text("modified\n", encoding="utf-8")
        self.git("commit", "-qam", "modify", repo=repo)
        modified = self.git("rev-parse", "HEAD", repo=repo).strip()
        path.write_text("original\n", encoding="utf-8")
        self.git("commit", "-qam", "restore", repo=repo)
        restored = self.git("rev-parse", "HEAD", repo=repo).strip()
        self.git("mv", "--", path.name, "改名 ファイル.txt", repo=repo)
        (repo / "binary.dat").write_bytes(b"\0changed")
        self.git("commit", "-qam", "rename and binary", repo=repo)
        renamed = self.git("rev-parse", "HEAD", repo=repo).strip()
        self.git("rm", "--", "改名 ファイル.txt", repo=repo)
        self.git("commit", "-qm", "delete", repo=repo)
        deleted = self.git("rev-parse", "HEAD", repo=repo).strip()
        commits = [added, modified, restored, renamed, deleted]
        args = [arg for commit in commits for arg in ("-c", commit)]
        result = self.run_helper("", "-m", "multi", *args, repo=repo)
        report = self.assert_selected_diff(result, commits, repo=repo)
        self.assertIn("+modified\n", report)
        self.assertIn("-modified\n", report)
        self.assertIn("rename from", report)
        self.assertIn("[バイナリ]", report)
        self.assertIn("状態: D", report)

    def test_multi_shallow_parent_is_an_error(self):
        shallow = self.root / "shallow multi"
        self.git("clone", "-q", "--depth=1", "--branch", "main", self.repo.as_uri(),
                 str(shallow))
        result = self.run_helper("", "-m", "multi", "-c", "HEAD", repo=shallow)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("親コミットが取得できません", result.stderr)
        self.assertFalse(self.output.exists())

    def test_multi_outputs_and_worktree_are_preserved(self):
        commands = (("symbolic-ref", "HEAD"), ("status", "--porcelain=v1", "-z"),
                    ("diff", "--binary"), ("diff", "--cached", "--binary"),
                    ("for-each-ref", "--format=%(refname) %(objectname)"))
        before = [self.git(*args) for args in commands]
        selected = [self.commits[0], self.commits[22]]
        command = [arg for arg in self.command("-m", "multi", "-c", selected[0], "-c",
                                               selected[1], "-x", "xlsx")
                   if arg not in ("--no-md", "--no-excel")]
        result = subprocess.run(command, input="", env=self.env, capture_output=True,
                                text=True, encoding="utf-8", timeout=60)
        self.assert_selected_diff(result, selected)
        self.assertEqual([self.git(*args) for args in commands], before)
        markdown = next(self.output.glob("*.md")).read_text(encoding="utf-8")
        self.assertIn("選択コミット数", markdown)
        self.assertEqual(len(re.findall(r"^### \[\d+/2\]", markdown, re.M)), 2)
        with zipfile.ZipFile(next(self.output.glob("*.xlsx"))) as archive:
            for name in archive.namelist():
                if name.endswith((".xml", ".rels")):
                    ET.fromstring(archive.read(name))
            self.assertIn("コミット: " + selected[0], archive.read("xl/worksheets/sheet3.xml").decode())


if __name__ == "__main__":
    unittest.main()
