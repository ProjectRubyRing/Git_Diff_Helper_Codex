#!/usr/bin/env bash
#==============================================================================
#  git-diff-helper.sh  -  Git 差分ヘルパー
#------------------------------------------------------------------------------
#  対象環境 : Red Hat Enterprise Linux 9.6 (bash 5.x / GNU awk / git 2.x)
#  概要     : ワークツリー／ステージ／コミット／ブランチ／リモート追跡ブランチ
#             などの各種 git 差分を、パラメータ指定ひとつで取得し、
#               (1) 画面          … 色付き・行番号付きの見やすい表示
#               (2) テキスト(.txt) … 画面表示と同内容 + 生の git diff
#               (3) Markdown(.md)  … GitHub 等でそのまま読める差分レポート
#               (4) Excel(xlsx)    … サマリ／ファイル一覧／差分明細／コミット履歴
#             の 4 形態で出力する。
#             さらに (5) 利用ガイド Excel (使い方マニュアル) を
#             Meiryo UI フォントで整形して追加出力する。
#  依存     : git, bash, awk(gawk 推奨), coreutils, tr
#             xlsx 出力には zip もしくは python3 のいずれかが必要
#             (どちらも無い場合は自動的に CSV 出力へフォールバック)
#  ライセンス: MIT
#==============================================================================

set -uo pipefail

SCRIPT_NAME="$(basename -- "$0")"
VERSION="1.3.0"

#------------------------------------------------------------------------------
# 既定値
#------------------------------------------------------------------------------
MODE=""
FROM=""
TO=""
SELECT_BRANCH_DEFAULT="main"
SELECT_BRANCH_SET=0
HISTORY_BRANCH=""
HISTORY_TIP=""
COMMIT_REFS=()
SELECTED_COMMITS=()
declare -A SELECTED_SET=()
BACK=1
REPO="."
OUTDIR=""
PREFIX="git-diff"
CONTEXT=3
MERGE_BASE="auto"          # auto | yes | no
EXCEL_FMT="auto"           # auto | xlsx | csv | none
DO_SCREEN=1
DO_TEXT=1
DO_MD=1
DO_EXCEL=1
DO_MANUAL=1                # 利用ガイド Excel を追加出力する
MANUAL_FORCED=0            # --manual が明示指定された
MANUAL_ONLY=0              # 利用ガイドのみ生成して終了
MD_LINENOS=0               # Markdown の差分行に旧/新行番号を付ける
IGNORE_SPACE=0
FIND_RENAMES=1
USE_COLOR="auto"           # auto | yes | no
ASCII="auto"               # auto | yes | no
SUMMARY_ONLY=0
MAX_LINES=0                # 1ファイルあたりの差分明細表示上限 (0=無制限)
EXCEL_MAX_ROWS=100000
INCLUDE_RAW=1
USE_PAGER=0
PATHSPEC=()

#------------------------------------------------------------------------------
# メッセージ出力
#------------------------------------------------------------------------------
err()  { printf '%s\n' "[エラー] $*" >&2; }
warn() { printf '%s\n' "[警告] $*" >&2; }
info() { printf '%s\n' "[情報] $*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<'EOS'
================================================================================
 git-diff-helper.sh - Git 差分ヘルパー
================================================================================
 各種 git 差分を「画面」「テキスト(.txt)」「Markdown(.md)」「Excel(.xlsx)」に
 出力します。あわせて、詳しい利用方法をまとめた「利用ガイド Excel」を
 Meiryo UI フォントで整形して追加出力します。

【書式】
  git-diff-helper.sh -m <モード> [オプション] [-- <パス指定>...]
  git-diff-helper.sh --manual-only [-o <出力先>]    ← 利用ガイドのみ生成

【モード】 -m / --mode
  worktree   ワークツリー ⇔ ステージ(インデックス)      … git diff
             別名: wt, unstaged
  staged     ステージ(インデックス) ⇔ HEAD              … git diff --cached
             別名: cached, index
  head       ワークツリー ⇔ 最新コミット(HEAD)          … git diff HEAD
             別名: latest
  prev       1つ前のコミット(HEAD~N) ⇔ HEAD             … git diff HEAD~N HEAD
             別名: last     ※ -n / --back で N を変更 (既定 1)
  commit     指定コミットが加えた変更(親 ⇔ 指定コミット)… -f で対象コミット指定
  commits    特定の2コミット間                          … git diff <from> <to>
             別名: range    ※ -f / -t で指定
  interactive ブランチと2コミットを対話的に選択         … git diff <from> <to>
             別名: select   ※ ブランチ既定 main、履歴は10件ずつ表示
  multi      複数コミットの変更をファイル単位で集約       … 各コミットの親との差分
             別名: multi-select  ※ 対話選択、または -c を繰り返して指定
  branches   ブランチ同士の変更                          … git diff <from>...<to>
             別名: branch   ※ -f / -t で指定 (既定は三点比較)
  remote     リモート追跡ブランチ ⇔ ローカル HEAD        … git diff <upstream> HEAD
             別名: upstream ※ -t で追跡先を明示指定可 (例: origin/main)

【主なオプション】
  -f, --from <REF>       比較元 (コミット / ブランチ / タグ / SHA)
  -t, --to   <REF>       比較先 (省略時は HEAD)
  -b, --branch <BRANCH>  interactive / multi のブランチ選択の既定値 (既定: main)
  -c, --commit <REF>     multi の対象コミット (繰り返し指定可、省略時は対話選択)
  -n, --back <N>         prev モードで N 個前のコミットと比較 (既定: 1)
  -r, --repo <DIR>       対象リポジトリのパス (既定: カレントディレクトリ)
  -o, --outdir <DIR>     出力先ディレクトリ (既定: ./git-diff-report)
      --prefix <NAME>    出力ファイル名の接頭辞 (既定: git-diff)
  -U, --context <N>      差分の前後コンテキスト行数 (既定: 3)
      --merge-base       ブランチ/リモート比較で三点比較 (A...B) を使用
      --no-merge-base    二点比較 (A B) を使用
  -w, --ignore-space     空白のみの差分を無視
      --no-renames       リネーム検出を行わない
  -x, --excel <FMT>      Excel 出力形式: auto | xlsx | csv | none (既定: auto)
      --no-excel         Excel 出力を行わない
      --no-text          テキストファイル出力を行わない
      --no-md            Markdown ファイル出力を行わない
      --md-linenos       Markdown の差分行に旧/新行番号を併記する
      --no-screen        画面出力を行わない
      --no-raw           テキスト/Markdown 出力に生の git diff を含めない
      --summary-only     差分明細を出さずサマリのみ表示
      --max-lines <N>    1ファイルあたりの明細表示行数上限 (0=無制限)
      --excel-max-rows <N> 差分明細シートの最大行数 (既定: 100000)
      --ascii            罫線などを ASCII 文字のみで描画
      --no-color         画面出力を色無しにする
      --color            画面出力を必ず色付きにする
      --pager            画面出力を less -R に流す
      --manual           利用ガイド Excel を必ず出力する
      --no-manual        利用ガイド Excel を出力しない
      --manual-only      利用ガイド Excel だけを生成して終了 (モード指定不要)
  -l, --list-modes       モード一覧を表示して終了
  -h, --help             このヘルプを表示
  -V, --version          バージョンを表示

【使用例】
  # ワークツリーとステージの差分
  ./git-diff-helper.sh -m worktree

  # ステージと HEAD の差分を /tmp/report へ出力
  ./git-diff-helper.sh -m staged -o /tmp/report

  # 最新コミットとの差分 (未コミットの変更すべて)
  ./git-diff-helper.sh -m head

  # 3つ前のコミットから現在までの差分
  ./git-diff-helper.sh -m prev -n 3

  # 特定の2コミット間の差分
  ./git-diff-helper.sh -m commits -f a1b2c3d -t f9e8d7c

  # ブランチと比較元・比較先を選ぶ (n: 次ページ / p: 前ページ / q: 中止)
  ./git-diff-helper.sh -m interactive
  ./git-diff-helper.sh -m interactive -b develop -r /srv/git/myapp

  # 複数選択 (番号を空白/カンマ区切りで切替、n/p: ページ移動、d: 確定、q: 中止)
  ./git-diff-helper.sh -m multi
  ./git-diff-helper.sh -m multi -c a1b2c3d -c f9e8d7c

  # ブランチ間の差分 (main を基点にした feature の変更)
  ./git-diff-helper.sh -m branches -f main -t feature/login

  # リモート追跡ブランチとの差分
  ./git-diff-helper.sh -m remote
  ./git-diff-helper.sh -m remote -t origin/develop

  # 特定ディレクトリのみを対象にする
  ./git-diff-helper.sh -m head -- src/ docs/README.md

  # 利用ガイド (使い方マニュアル) の Excel だけを作る
  ./git-diff-helper.sh --manual-only -o ./docs

【出力ファイル】
  <出力先>/<接頭辞>_<モード>_<日時>.txt        テキストレポート
  <出力先>/<接頭辞>_<モード>_<日時>.md         Markdown レポート
  <出力先>/<接頭辞>_<モード>_<日時>.xlsx       Excel レポート (4シート)
  <出力先>/<接頭辞>_使い方ガイド_<日時>.xlsx   利用ガイド Excel (9シート)
================================================================================
EOS
}

list_modes() {
  cat <<'EOS'
モード      別名                比較内容
----------  ------------------  --------------------------------------------
worktree    wt, unstaged        ワークツリー ⇔ ステージ(インデックス)
staged      cached, index       ステージ ⇔ HEAD
head        latest              ワークツリー ⇔ 最新コミット(HEAD)
prev        last                HEAD~N ⇔ HEAD  (-n で N 指定)
commit                          指定コミットの親 ⇔ 指定コミット (-f)
commits     range               指定した2コミット間 (-f, -t)
interactive select              ブランチと2コミットを選択 (既定 main / 10件ずつ)
multi       multi-select        選択コミットの親との差分を集約 (対話選択 / -c を反復)
branches    branch              ブランチ同士 (-f, -t)
remote      upstream            リモート追跡ブランチ ⇔ HEAD (-t で明示指定)
EOS
}

#------------------------------------------------------------------------------
# 引数解析
#------------------------------------------------------------------------------
parse_args() {
  while (($#)); do
    case "$1" in
      -m|--mode)            [[ $# -ge 2 ]] || die "$1 には値が必要です"; MODE="$2"; shift 2 ;;
      -f|--from)            [[ $# -ge 2 ]] || die "$1 には値が必要です"; FROM="$2"; shift 2 ;;
      -t|--to)              [[ $# -ge 2 ]] || die "$1 には値が必要です"; TO="$2"; shift 2 ;;
      -b|--branch)          [[ $# -ge 2 && -n "$2" ]] || die "$1 には値が必要です"; SELECT_BRANCH_DEFAULT="$2"; SELECT_BRANCH_SET=1; shift 2 ;;
      -c|--commit)          [[ $# -ge 2 && -n "$2" ]] || die "$1 には値が必要です"; COMMIT_REFS+=("$2"); shift 2 ;;
      -n|--back)            [[ $# -ge 2 ]] || die "$1 には値が必要です"; BACK="$2"; shift 2 ;;
      -r|--repo)            [[ $# -ge 2 ]] || die "$1 には値が必要です"; REPO="$2"; shift 2 ;;
      -o|--outdir)          [[ $# -ge 2 ]] || die "$1 には値が必要です"; OUTDIR="$2"; shift 2 ;;
      --prefix)             [[ $# -ge 2 ]] || die "$1 には値が必要です"; PREFIX="$2"; shift 2 ;;
      -U|--context)         [[ $# -ge 2 ]] || die "$1 には値が必要です"; CONTEXT="$2"; shift 2 ;;
      -x|--excel)           [[ $# -ge 2 ]] || die "$1 には値が必要です"; EXCEL_FMT="$2"; shift 2 ;;
      --max-lines)          [[ $# -ge 2 ]] || die "$1 には値が必要です"; MAX_LINES="$2"; shift 2 ;;
      --excel-max-rows)     [[ $# -ge 2 ]] || die "$1 には値が必要です"; EXCEL_MAX_ROWS="$2"; shift 2 ;;
      --merge-base)         MERGE_BASE="yes"; shift ;;
      --no-merge-base)      MERGE_BASE="no"; shift ;;
      -w|--ignore-space)    IGNORE_SPACE=1; shift ;;
      --no-renames)         FIND_RENAMES=0; shift ;;
      --no-excel)           DO_EXCEL=0; shift ;;
      --no-text)            DO_TEXT=0; shift ;;
      --no-md|--no-markdown) DO_MD=0; shift ;;
      --md|--markdown)      DO_MD=1; shift ;;
      --md-linenos)         MD_LINENOS=1; shift ;;
      --manual|--guide)     DO_MANUAL=1; MANUAL_FORCED=1; shift ;;
      --no-manual|--no-guide) DO_MANUAL=0; shift ;;
      --manual-only)        MANUAL_ONLY=1; DO_MANUAL=1; MANUAL_FORCED=1; shift ;;
      --no-screen)          DO_SCREEN=0; shift ;;
      --no-raw)             INCLUDE_RAW=0; shift ;;
      --summary-only)       SUMMARY_ONLY=1; shift ;;
      --ascii)              ASCII="yes"; shift ;;
      --no-color)           USE_COLOR="no"; shift ;;
      --color)              USE_COLOR="yes"; shift ;;
      --pager)              USE_PAGER=1; shift ;;
      -l|--list-modes)      list_modes; exit 0 ;;
      -h|--help)            usage; exit 0 ;;
      -V|--version)         printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
      --)                   shift; while (($#)); do PATHSPEC+=("$1"); shift; done ;;
      -*)                   die "不明なオプション: $1  (--help でヘルプを表示)" ;;
      *)                    if [[ -z "$MODE" ]]; then MODE="$1"; shift
                            else die "余分な引数: $1  (パス指定は -- の後に記述してください)"; fi ;;
    esac
  done
}

#------------------------------------------------------------------------------
# 画面装飾の設定
#------------------------------------------------------------------------------
setup_style() {
  if [[ "$USE_COLOR" == "auto" ]]; then
    if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then USE_COLOR="yes"; else USE_COLOR="no"; fi
  fi
  if [[ "$ASCII" == "auto" ]]; then
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
      *UTF-8*|*utf8*|*UTF8*|*utf-8*) ASCII="no" ;;
      *) ASCII="yes" ;;
    esac
  fi
}

#------------------------------------------------------------------------------
# awk のロケール判定
#   日本語(全角)の桁揃えには awk が多バイト対応で動作する必要があるため、
#   現在のロケールが非 UTF-8 の場合は UTF-8 ロケールを補って awk を起動する。
#------------------------------------------------------------------------------
AWK=(awk)
detect_awk_locale() {
  awk 'BEGIN{exit !(length("あ")==1)}' </dev/null 2>/dev/null && return 0
  local L
  for L in C.UTF-8 C.utf8 en_US.UTF-8 ja_JP.UTF-8 ja_JP.utf8; do
    if LC_ALL="$L" awk 'BEGIN{exit !(length("あ")==1)}' </dev/null 2>/dev/null; then
      AWK=(env LC_ALL="$L" awk); return 0
    fi
  done
  return 0
}

#------------------------------------------------------------------------------
# 前提チェック
#------------------------------------------------------------------------------
check_prereq() {
  command -v git  >/dev/null 2>&1 || die "git コマンドが見つかりません。"
  command -v awk  >/dev/null 2>&1 || die "awk コマンドが見つかりません。"
  command -v tr   >/dev/null 2>&1 || die "tr コマンドが見つかりません。"
  [[ -d "$REPO" ]] || die "リポジトリのパスが存在しません: $REPO"
  GIT=(git -C "$REPO" -c core.quotepath=false)
  "${GIT[@]}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "git リポジトリではありません: $REPO"
  REPO_ROOT="$("${GIT[@]}" rev-parse --show-toplevel 2>/dev/null)"
  [[ -n "$REPO_ROOT" ]] || REPO_ROOT="$(cd -- "$REPO" && pwd)"
  [[ "$CONTEXT"        =~ ^[0-9]+$ ]] || die "--context には 0 以上の整数を指定してください: $CONTEXT"
  [[ "$BACK"           =~ ^[0-9]+$ ]] || die "--back には 1 以上の整数を指定してください: $BACK"
  [[ "$MAX_LINES"      =~ ^[0-9]+$ ]] || die "--max-lines には 0 以上の整数を指定してください: $MAX_LINES"
  [[ "$EXCEL_MAX_ROWS" =~ ^[0-9]+$ ]] || die "--excel-max-rows には 0 以上の整数を指定してください"
  ((BACK >= 1)) || die "--back には 1 以上の整数を指定してください: $BACK"
}

# ref の存在確認
verify_ref() {
  "${GIT[@]}" rev-parse --verify --quiet "$1^{commit}" >/dev/null 2>&1
}

has_head() { "${GIT[@]}" rev-parse --verify --quiet HEAD >/dev/null 2>&1; }

#------------------------------------------------------------------------------
# 対話選択 (案内は標準エラー、入力は標準入力。レポートには混ぜない)
#------------------------------------------------------------------------------
read_selection() {
  printf '%s' "$1" >&2
  IFS= read -r SELECTION_INPUT || die "選択入力が終了しました。対話操作を行うか、-m commits -f <元> -t <先> / -m multi -c <対象> ... を指定してください。"
  SELECTION_INPUT="${SELECTION_INPUT%$'\r'}"
  case "$SELECTION_INPUT" in
    q|Q) info "コミット選択を中止しました。"; exit 0 ;;
  esac
}

select_history_branch() {
  local branch_output ref oid symbolic i choice label
  local refs=() tips=()
  branch_output="$("${GIT[@]}" --no-pager for-each-ref --sort=refname \
    --format='%(refname)%09%(objectname)%09%(symref)' refs/heads/ refs/remotes/)" \
    || die "ブランチ一覧の取得に失敗しました。"
  while IFS=$'\t' read -r ref oid symbolic; do
    [[ -n "$ref" && -z "$symbolic" ]] || continue
    refs+=("$ref"); tips+=("$oid")
  done <<< "$branch_output"
  ((${#refs[@]} > 0)) || die "選択できるブランチがありません。コミットのあるローカル／リモート追跡ブランチが必要です。"

  while :; do
    printf '\n[ ブランチ選択 ]\n' >&2
    for ((i = 0; i < ${#refs[@]}; i++)); do
      ref="${refs[i]}"
      case "$ref" in
        refs/heads/*)   label="${ref#refs/heads/} (ローカル)" ;;
        refs/remotes/*) label="${ref#refs/remotes/} (リモート追跡)" ;;
      esac
      printf '  %3d) %s\n' "$((i + 1))" "$label" >&2
    done
    read_selection "ブランチ番号または名前 [${SELECT_BRANCH_DEFAULT}] (q: 中止): "
    choice=-1
    # 入力を算術式として評価せず、表示した番号と文字列として照合する。
    if [[ -n "$SELECTION_INPUT" ]]; then
      for ((i = 0; i < ${#refs[@]}; i++)); do
        if [[ "$SELECTION_INPUT" == "$((i + 1))" ]]; then choice=$i; break; fi
      done
    else
      SELECTION_INPUT="$SELECT_BRANCH_DEFAULT"
    fi
    if ((choice < 0)); then
      for ((i = 0; i < ${#refs[@]}; i++)); do
        ref="${refs[i]}"
        if [[ "$SELECTION_INPUT" == "$ref" || "refs/heads/$SELECTION_INPUT" == "$ref" || "refs/remotes/$SELECTION_INPUT" == "$ref" ]]; then
          choice=$i; break
        fi
      done
    fi
    if ((choice < 0)); then
      warn "ブランチが見つかりません: $SELECTION_INPUT。一覧の番号または名前を入力してください。"
      continue
    fi
    HISTORY_BRANCH="${refs[choice]}"
    # 操作中にブランチが更新されても、一覧と差分が同じ履歴を参照するよう固定する。
    HISTORY_TIP="${tips[choice]}"
    verify_ref "$HISTORY_TIP" || die "選択したブランチのコミットが解決できません: $HISTORY_BRANCH"
    return 0
  done
}

select_history_commit() {
  local prompt="$1" excluded="${2:-}" page=0 page_size=10 page_output oid details
  local multiple="${3:-0}" count has_next i marker token valid
  local hashes=() labels=() choices=() pending=() remaining=()
  local -A seen_choice=()
  while :; do
    # 1件先読みして次ページの有無を判定し、全履歴の読み込み・件数集計を避ける。
    page_output="$("${GIT[@]}" --no-pager log --no-color --no-decorate --no-notes \
      --no-show-signature --no-patch --date-order --skip="$((page * page_size))" \
      --max-count="$((page_size + 1))" --date=format:'%Y-%m-%d %H:%M:%S %z' \
      --format='%H%x09%h  %cd  %an  %s' "$HISTORY_TIP" --)" \
      || die "コミット履歴の取得に失敗しました: $HISTORY_BRANCH (ページ $((page + 1)))"
    hashes=(); labels=()
    while IFS=$'\t' read -r oid details; do
      [[ -n "$oid" ]] || continue
      hashes+=("$oid")
      # コミットの件名・作成者に含まれる端末制御文字は実行せず空白に置き換える。
      labels+=("${details//[[:cntrl:]]/ }")
    done <<< "$page_output"
    count=${#hashes[@]}; has_next=0
    ((count > 0)) || die "表示できるコミットがありません: $HISTORY_BRANCH"
    if ((count > page_size)); then count=$page_size; has_next=1; fi
    printf '\n[ %s ] %s / ページ %d (%d～%d件目)\n' \
      "$prompt" "$HISTORY_BRANCH" "$((page + 1))" "$((page * page_size + 1))" "$((page * page_size + count))" >&2
    printf '  番号  コミット  日時  作成者  件名\n' >&2
    for ((i = 0; i < count; i++)); do
      marker=""
      if ((multiple)); then
        marker="[ ] "
        [[ -n "${SELECTED_SET[${hashes[i]}]:-}" ]] && marker="[x] "
      fi
      printf '  %2d) %s%s\n' "$((i + 1))" "$marker" "${labels[i]}" >&2
    done
    if ((multiple)); then
      printf '  選択済み: %d 件 / 番号: 選択・解除 (例: 1 3 または 1,3) / d: 確定\n' "${#SELECTED_COMMITS[@]}" >&2
      printf '  n: 次の10件 / p: 前の10件 / q: 中止 (入力後 Enter)\n' >&2
    else
      printf '  番号: 選択 / n: 次の10件 / p: 前の10件 / q: 中止 (入力後 Enter)\n' >&2
    fi
    read_selection '選択: '
    case "$SELECTION_INPUT" in
      n|N)
        if ((has_next)); then page=$((page + 1)); else warn "最後のページです。"; fi
        ;;
      p|P)
        if ((page > 0)); then page=$((page - 1)); else warn "最初のページです。"; fi
        ;;
      *)
        if ((multiple)); then
          if [[ "$SELECTION_INPUT" == "d" || "$SELECTION_INPUT" == "D" ]]; then
            ((${#SELECTED_COMMITS[@]} > 0)) && return 0
            warn "1件以上のコミットを選択してください。"
            continue
          fi
          IFS=$' \t' read -r -a choices <<< "${SELECTION_INPUT//,/ }"
          pending=(); seen_choice=(); valid=1
          ((${#choices[@]} > 0)) || valid=0
          # 全番号を先に検証し、不正な入力では選択状態を一切変えない。
          for token in "${choices[@]}"; do
            for ((i = 0; i < count; i++)); do
              [[ "$token" == "$((i + 1))" ]] && break
            done
            if ((i == count)); then valid=0; break; fi
            oid="${hashes[i]}"
            if [[ -z "${seen_choice[$oid]:-}" ]]; then
              pending+=("$oid"); seen_choice[$oid]=1
            fi
          done
          if ((valid == 0)); then
            warn "表示中の番号 (1～${count}) を空白／カンマで区切るか、n、p、d、q を入力してください。"
            continue
          fi
          for oid in "${pending[@]}"; do
            if [[ -n "${SELECTED_SET[$oid]:-}" ]]; then
              unset 'SELECTED_SET[$oid]'
            else
              SELECTED_SET[$oid]=1; SELECTED_COMMITS+=("$oid")
            fi
          done
          remaining=()
          for oid in "${SELECTED_COMMITS[@]}"; do
            [[ -n "${SELECTED_SET[$oid]:-}" ]] && remaining+=("$oid")
          done
          SELECTED_COMMITS=("${remaining[@]}")
          continue
        fi
        for ((i = 0; i < count; i++)); do
          if [[ "$SELECTION_INPUT" == "$((i + 1))" ]]; then
            if [[ "${hashes[i]}" == "$excluded" ]]; then
              warn "比較元と異なるコミットを選択してください。"
              break
            fi
            SELECTED_COMMIT="${hashes[i]}"
            info "$prompt: ${labels[i]}"
            return 0
          fi
        done
        ((i < count)) || warn "表示中の番号 (1～${count})、n、p、q のいずれかを入力してください。"
        ;;
    esac
  done
}

select_commit_range() {
  select_history_branch
  local count
  count="$("${GIT[@]}" rev-list --count --max-count=2 "$HISTORY_TIP" --)" \
    || die "コミット数の確認に失敗しました: $HISTORY_BRANCH"
  ((count >= 2)) || die "2点間の比較には、選択したブランチに2件以上のコミットが必要です: $HISTORY_BRANCH"
  info "履歴は新しい順に表示します。比較元 (変更前)、比較先 (変更後) の順で選択してください。"
  select_history_commit "比較元 (変更前)"
  FROM="$SELECTED_COMMIT"
  select_history_commit "比較先 (変更後)" "$FROM"
  TO="$SELECTED_COMMIT"
}

select_multiple_commits() {
  local ref oid
  if ((${#COMMIT_REFS[@]})); then
    ((SELECT_BRANCH_SET == 0)) || die "-c / --commit と --branch は併用できません。"
    for ref in "${COMMIT_REFS[@]}"; do
      oid="$("${GIT[@]}" rev-parse --verify --end-of-options "${ref}^{commit}")" \
        || die "対象コミットが解決できません: $ref"
      if [[ -z "${SELECTED_SET[$oid]:-}" ]]; then
        SELECTED_COMMITS+=("$oid"); SELECTED_SET[$oid]=1
      fi
    done
  else
    select_history_branch
    info "各コミットの親との差分を集約します。番号で選択・解除し、d で確定してください。"
    select_history_commit "複数コミット選択" "" 1
  fi
}

#------------------------------------------------------------------------------
# モード解決  →  RANGE / 各種ラベルを決定
#------------------------------------------------------------------------------
EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"

resolve_mode() {
  RANGE=()
  LOG_RANGE=""
  case "$MODE" in
    wt|worktree|unstaged)     MODE="worktree" ;;
    staged|cached|index)      MODE="staged" ;;
    head|latest)              MODE="head" ;;
    prev|last)                MODE="prev" ;;
    commit)                   MODE="commit" ;;
    commits|range)            MODE="commits" ;;
    interactive|select)       MODE="interactive" ;;
    multi|multi-select)       MODE="multi" ;;
    branch|branches)          MODE="branches" ;;
    remote|upstream)          MODE="remote" ;;
    "")  usage; echo; die "モードが指定されていません。 -m <モード> を指定してください。" ;;
    *)   die "不明なモード: $MODE  ( -l でモード一覧を表示 )" ;;
  esac

  if ((SELECT_BRANCH_SET)) && [[ "$MODE" != "interactive" && "$MODE" != "multi" ]]; then
    die "--branch は interactive / multi モードで使用してください。"
  fi
  if ((${#COMMIT_REFS[@]})) && [[ "$MODE" != "multi" ]]; then
    die "-c / --commit は multi モードで使用してください。"
  fi

  case "$MODE" in
    worktree)
      RANGE=()
      MODE_DESC="ワークツリー ⇔ ステージ(インデックス)"
      SIDE_L="ステージ(インデックス)"
      SIDE_R="ワークツリー(作業ツリー)"
      MODE_NOTE="まだ git add していない変更を確認します。"
      ;;
    staged)
      if [[ -n "$FROM" ]]; then
        verify_ref "$FROM" || die "比較元が解決できません: $FROM"
        RANGE=(--cached "$FROM"); SIDE_L="$FROM"
      elif has_head; then
        RANGE=(--cached); SIDE_L="HEAD (最新コミット)"
      else
        info "コミットが1件もないため、空の状態と比較します(初回コミット前)。"
        RANGE=(--cached "$EMPTY_TREE"); SIDE_L="空(初回コミット前)"
      fi
      MODE_DESC="ステージ(インデックス) ⇔ ${SIDE_L}"
      SIDE_R="ステージ(インデックス)"
      MODE_NOTE="git add 済みで、まだコミットしていない変更を確認します。"
      ;;
    head)
      if has_head; then
        RANGE=(HEAD); SIDE_L="HEAD (最新コミット)"
      else
        info "コミットが1件もないため、空の状態と比較します(初回コミット前)。"
        RANGE=("$EMPTY_TREE"); SIDE_L="空(初回コミット前)"
      fi
      MODE_DESC="ワークツリー ⇔ ${SIDE_L}"
      SIDE_R="ワークツリー(作業ツリー)"
      MODE_NOTE="ステージ済み・未ステージを問わず、未コミットの変更をすべて確認します。"
      ;;
    prev)
      has_head || die "コミットが1件もありません。"
      local base="HEAD~${BACK}"
      if verify_ref "$base"; then :; else
        warn "HEAD~${BACK} が存在しないため、最初のコミット以前(空ツリー)を比較元にします。"
        base="$EMPTY_TREE"
      fi
      RANGE=("$base" HEAD)
      if [[ "$base" == "$EMPTY_TREE" ]]; then
        LOG_RANGE="HEAD"; SIDE_L="リポジトリの最初(空の状態)"
      else
        LOG_RANGE="${base}..HEAD"; SIDE_L="${BACK} 個前のコミット (${base})"
      fi
      SIDE_R="HEAD (最新コミット)"
      MODE_DESC="${SIDE_L} ⇔ ${SIDE_R}"
      MODE_NOTE="直近 ${BACK} 件のコミットで加えられた変更を確認します。"
      ;;
    commit)
      [[ -n "$FROM" ]] || die "commit モードでは -f <コミット> で対象コミットを指定してください。"
      verify_ref "$FROM" || die "コミットが解決できません: $FROM"
      local target parent
      target="$("${GIT[@]}" rev-parse --verify "${FROM}^{commit}")"
      if "${GIT[@]}" rev-parse --verify --quiet "${target}^" >/dev/null 2>&1; then
        parent="$("${GIT[@]}" rev-parse --verify "${target}^")"
      else
        parent="$EMPTY_TREE"
        warn "指定コミットは最初のコミットです。空ツリーとの比較になります。"
      fi
      RANGE=("$parent" "$target")
      if [[ "$parent" == "$EMPTY_TREE" ]]; then
        LOG_RANGE="$target"; SIDE_L="空の状態(最初のコミットのため)"
      else
        LOG_RANGE="${parent}..${target}"; SIDE_L="親コミット (${parent:0:12})"
      fi
      SIDE_R="対象コミット (${FROM} = ${target:0:12})"
      MODE_DESC="${SIDE_L} ⇔ ${SIDE_R}"
      MODE_NOTE="指定した1コミットが加えた変更内容を確認します。"
      ;;
    commits|interactive)
      if [[ "$MODE" == "interactive" ]]; then
        [[ -z "$FROM" && -z "$TO" ]] || die "interactive モードでは -f / -t を使わず、画面から2コミットを選択してください。"
        [[ "$MERGE_BASE" != "yes" ]] || die "interactive モードは二点比較です。--merge-base は指定できません。"
        select_commit_range
      fi
      [[ -n "$FROM" ]] || die "commits モードでは -f <コミット> を指定してください。"
      [[ -n "$TO" ]] || { TO="HEAD"; info "-t が未指定のため比較先を HEAD にします。"; }
      verify_ref "$FROM" || die "比較元コミットが解決できません: $FROM"
      verify_ref "$TO"   || die "比較先コミットが解決できません: $TO"
      if [[ "$MERGE_BASE" == "yes" ]]; then
        RANGE=("${FROM}...${TO}"); MODE_DESC="${FROM} と ${TO} の共通祖先 ⇔ ${TO} (三点比較)"
      else
        RANGE=("$FROM" "$TO");     MODE_DESC="${FROM} ⇔ ${TO} (二点比較)"
      fi
      LOG_RANGE="${FROM}..${TO}"
      SIDE_L="$FROM ($("${GIT[@]}" rev-parse --short "$FROM"))"
      SIDE_R="$TO ($("${GIT[@]}" rev-parse --short "$TO"))"
      MODE_NOTE="指定した2つのコミット間の変更を確認します。"
      ;;
    multi)
      [[ -z "$FROM" && -z "$TO" ]] || die "multi モードでは -f / -t を使わず、対話選択または -c でコミットを指定してください。"
      [[ "$MERGE_BASE" != "yes" ]] || die "multi モードでは --merge-base は指定できません。"
      select_multiple_commits
      MODE_DESC="選択した ${#SELECTED_COMMITS[@]} コミットの変更を集約"
      SIDE_L="各コミットの第1親 (初回コミットは空ツリー)"
      SIDE_R="選択コミット (選択順)"
      MODE_NOTE="選択コミットごとの追加・削除行数を合算します。同一パスを集約し、変更を相殺しません。明細の行番号は各コミットの親／対象に対応します。"
      ;;
    branches)
      [[ -n "$FROM" ]] || die "branches モードでは -f <ブランチ> を指定してください。"
      [[ -n "$TO" ]] || { TO="HEAD"; info "-t が未指定のため比較先を HEAD にします。"; }
      verify_ref "$FROM" || die "比較元ブランチが解決できません: $FROM"
      verify_ref "$TO"   || die "比較先ブランチが解決できません: $TO"
      if [[ "$MERGE_BASE" == "no" ]]; then
        RANGE=("$FROM" "$TO")
        MODE_DESC="ブランチ ${FROM} ⇔ ${TO} (二点比較)"
        MODE_NOTE="2つのブランチの先端同士を単純比較します。"
      else
        RANGE=("${FROM}...${TO}")
        MODE_DESC="ブランチ ${FROM} と ${TO} の共通祖先 ⇔ ${TO} (三点比較)"
        MODE_NOTE="${FROM} から分岐した後に ${TO} 側で加えられた変更のみを確認します。"
      fi
      LOG_RANGE="${FROM}..${TO}"
      SIDE_L="$FROM ($("${GIT[@]}" rev-parse --short "$FROM"))"
      SIDE_R="$TO ($("${GIT[@]}" rev-parse --short "$TO"))"
      ;;
    remote)
      has_head || die "コミットが1件もありません。"
      local up
      if [[ -n "$TO" ]]; then
        up="$TO"
      else
        up="$("${GIT[@]}" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"
        [[ -n "$up" ]] || die "リモート追跡ブランチが設定されていません。
  例) git branch --set-upstream-to=origin/main
  もしくは -t origin/main のように比較先を明示指定してください。"
      fi
      verify_ref "$up" || die "リモート追跡ブランチが解決できません: $up
  git fetch を実行してから再度お試しください。"
      local local_ref="${FROM:-HEAD}"
      verify_ref "$local_ref" || die "ローカル側の参照が解決できません: $local_ref"
      if [[ "$MERGE_BASE" == "yes" ]]; then
        RANGE=("${up}...${local_ref}")
        MODE_DESC="リモート追跡 ${up} との共通祖先 ⇔ ${local_ref} (三点比較)"
      else
        RANGE=("$up" "$local_ref")
        MODE_DESC="リモート追跡ブランチ ${up} ⇔ ${local_ref} (二点比較)"
      fi
      LOG_RANGE="${up}..${local_ref}"
      SIDE_L="$up ($("${GIT[@]}" rev-parse --short "$up"))"
      SIDE_R="$local_ref ($("${GIT[@]}" rev-parse --short "$local_ref"))"
      UPSTREAM="$up"
      AHEAD_BEHIND="$("${GIT[@]}" rev-list --left-right --count "${up}...${local_ref}" 2>/dev/null | tr '\t' ' ')"
      MODE_NOTE="リモート追跡ブランチとローカルの差分を確認します。"
      ;;
  esac
}

#------------------------------------------------------------------------------
# git diff 共通オプション
#------------------------------------------------------------------------------
build_diff_opts() {
  DIFF_COMMON=(--no-ext-diff --no-color)
  if ((FIND_RENAMES)); then DIFF_COMMON+=(-M); else DIFF_COMMON+=(--no-renames); fi
  ((IGNORE_SPACE)) && DIFF_COMMON+=(-w)
  PS_ARGS=()
  [[ "$MODE" == "interactive" || "$MODE" == "multi" ]] && PS_ARGS=(--)
  ((${#PATHSPEC[@]})) && PS_ARGS=(-- "${PATHSPEC[@]}")
  DIFF_CMD_DISPLAY="git diff ${DIFF_COMMON[*]} -U${CONTEXT}"
  [[ "$MODE" == "multi" ]] && DIFF_CMD_DISPLAY+=" <各コミットの第1親/空ツリー> <選択コミット>"
  ((${#RANGE[@]}))    && DIFF_CMD_DISPLAY+=" ${RANGE[*]}"
  ((${#PS_ARGS[@]}))  && DIFF_CMD_DISPLAY+=" ${PS_ARGS[*]}"
}

git_diff() { "${GIT[@]}" diff "${DIFF_COMMON[@]}" "$@" ${RANGE[@]+"${RANGE[@]}"} ${PS_ARGS[@]+"${PS_ARGS[@]}"}; }

#==============================================================================
# awk プログラム群の展開
#==============================================================================
write_awk_programs() {

#--- 1) ファイル一覧の生成 (name-status + numstat をマージ) -------------------
cat >"$TMPD/files.awk" <<'AWKEOF'
BEGIN { US = sprintf("%c", 31) }
# --- 1ファイル目: name-status ---
FNR == NR {
  if ($0 == "") next
  if (want == 0) {
    ni++; st[ni] = $0
    if ($0 ~ /^[RC][0-9]*$/) want = 2; else want = 1
    got = 0
    next
  }
  got++
  if (want == 2) {
    if (got == 1) oldp[ni] = $0
    else { newp[ni] = $0; want = 0 }
  } else { oldp[ni] = $0; newp[ni] = $0; want = 0 }
  next
}
# --- 2ファイル目: numstat ---
{
  if ($0 == "") next
  if (pend > 0) { pend--; next }
  k++
  n = split($0, F, "\t")
  add[k] = F[1]; del[k] = F[2]
  if (!(n >= 3 && F[3] != "")) pend = 2
}
END {
  for (i = 1; i <= ni; i++) {
    code = st[i]
    ch = substr(code, 1, 1)
    sim = ""
    if (ch == "R" || ch == "C") sim = substr(code, 2)
    a = (add[i] == "" ? "0" : add[i]); d = (del[i] == "" ? "0" : del[i])
    bin = 0
    if (a == "-" || d == "-") { bin = 1; a = 0; d = 0 }
    printf "FILE%s%d%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n", \
      US, i, US, ch, US, code, US, a, US, d, US, oldp[i], US, newp[i], US, bin, US, sim
  }
}
AWKEOF

#--- 2) パッチ本文の解析 ------------------------------------------------------
cat >"$TMPD/patch.awk" <<'AWKEOF'
BEGIN { US = sprintf("%c", 31); fi = 0; inhunk = 0; inbin = 0 }
function emit(kind, ol, nl, txt) {
  gsub(/\r$/, "", txt)
  printf "LINE%s%d%s%d%s%s%s%s%s%s%s%s\n", US, fi, US, hn, US, ol, US, nl, US, kind, US, txt
}
/^diff --git / { fi++; hn = 0; inhunk = 0; inbin = 0; next }
/^index /      { next }
/^--- /        { if (!inhunk) next }
/^\+\+\+ /     { if (!inhunk) next }
!inhunk && /^(old|new) mode /            { emit("meta", "", "", $0); next }
!inhunk && /^(new|deleted) file mode /   { emit("meta", "", "", $0); next }
!inhunk && /^similarity index /          { emit("meta", "", "", $0); next }
!inhunk && /^(rename|copy) (from|to) /   { emit("meta", "", "", $0); next }
!inhunk && /^Binary files /              { emit("bin", "", "", $0); inbin = 1; next }
!inhunk && /^GIT binary patch/           { emit("bin", "", "", $0); inbin = 1; next }
/^@@ / {
  inhunk = 1; hn++
  line = $0
  sub(/^@@ /, "", line)
  p = index(line, " @@")
  spec = substr(line, 1, p - 1)
  head = (p + 4 <= length(line)) ? substr(line, p + 4) : ""
  split(spec, S, " ")
  o = S[1]; sub(/^-/, "", o); split(o, O, ","); ol = O[1] + 0; oc = (2 in O) ? O[2] + 0 : 1
  n = S[2]; sub(/^\+/, "", n); split(n, N, ","); nl = N[1] + 0; nc = (2 in N) ? N[2] + 0 : 1
  printf "LINE%s%d%s%d%s%s%s%s%s%s%s%s%s%d%s%d%s%d%s%d\n", \
    US, fi, US, hn, US, "", US, "", US, "hunk", US, head, US, ol, US, oc, US, nl, US, nc
  next
}
{
  if (inbin) next
  if (!inhunk) next
  c = substr($0, 1, 1)
  t = substr($0, 2)
  if (c == "+")      { emit("add", "", nl, t); nl++ }
  else if (c == "-") { emit("del", ol, "", t); ol++ }
  else if (c == " ") { emit("ctx", ol, nl, t); ol++; nl++ }
  else if (c == "\\"){ emit("note", "", "", $0) }
}
AWKEOF

#--- 選択コミットのファイルを集約し、明細をファイル→選択順に並べる -----------
cat >"$TMPD/selected.awk" <<'AWKEOF'
BEGIN { US = sprintf("%c", 31); FS = OFS = US }
function append_line(id, text,   name) {
  # 大きな差分をメモリに蓄積せず、数値IDの一時ファイルに保存する。
  name = dir "/" id ".dat"
  if (name != output) {
    if (output != "") close(output)
    output = name
  }
  print text >> output
}
$1 == "SELECT" { commit = $2; parent = $3; selection++; next }
$1 == "COMMIT" { commits[++ncommit] = $0; next }
$1 == "FILE" {
  key = "path:" $8
  id = bypath[key]
  if (!id) {
    id = ++nfile; bypath[key] = id
    state[id] = $3; oldp[id] = $7; newp[id] = $8; sim[id] = $10
  } else if (state[id] != $3 || oldp[id] != $7) {
    state[id] = "M"; oldp[id] = newp[id]; sim[id] = ""
  }
  if (!seen[id, $4]++) code[id] = code[id] (code[id] == "" ? "" : "/") $4
  adds[id] += $5; dels[id] += $6
  if ($9) binary[id] = 1
  byidx[selection, $2] = id
  append_line(id, "LINE" US id US 0 US "" US "" US "meta" US \
    "コミット: " commit " / 親: " parent " / 状態: " $4)
  next
}
$1 == "LINE" {
  $2 = byidx[selection, $2]
  append_line($2, $0)
}
END {
  if (output != "") close(output)
  for (i = 1; i <= nfile; i++)
    print "FILE", i, state[i], code[i], adds[i]+0, dels[i]+0, oldp[i], newp[i], binary[i]+0, sim[i]
  for (i = 1; i <= ncommit; i++) print commits[i]
  for (i = 1; i <= nfile; i++) {
    name = dir "/" i ".dat"
    while ((rc = (getline line < name)) > 0) print line
    close(name)
    if (rc < 0) exit 1
  }
}
AWKEOF

#--- 3) レポート描画 (画面 / テキスト共通) ------------------------------------
cat >"$TMPD/render.awk" <<'AWKEOF'
BEGIN {
  US = sprintf("%c", 31); FS = US
  if (color == 1) {
    R="\033[0m"; B="\033[1m"; D="\033[2m"
    RED="\033[31m"; GRN="\033[32m"; YEL="\033[33m"; BLU="\033[94m"; CYN="\033[36m"; GRY="\033[90m"; MAG="\033[35m"
  } else { R=""; B=""; D=""; RED=""; GRN=""; YEL=""; BLU=""; CYN=""; GRY=""; MAG="" }
  if (ascii == 1) {
    HL="-"; VL="|"; TL="+"; BLc="+"; BLK="#"; DOT="."; AR="->"; LR="<->"
  } else {
    HL="─"; VL="│"; TL="┌"; BLc="└"; BLK="▇"; DOT="·"; AR="→"; LR="⇔"
  }
  nfile = 0; ncommit = 0; nmeta = 0; printed = 0; curfile = -1; shown = 0
  W = width + 0; if (W < 40) W = 78
  # 全角(2桁幅)文字の範囲。gawk が多バイト対応の場合のみ使用する。
  WIDE = "[" sprintf("%c-%c", 4352, 4447) sprintf("%c-%c", 11904, 12350) \
             sprintf("%c-%c", 12353, 13311) sprintf("%c-%c", 13312, 19903) \
             sprintf("%c-%c", 19968, 40959) sprintf("%c-%c", 44032, 55203) \
             sprintf("%c-%c", 63744, 64255) sprintf("%c-%c", 65072, 65135) \
             sprintf("%c-%c", 65281, 65376) "]"
  MB = (length("あ") == 1)
  if (ascii == 1) { H_ST="STATUS"; H_ADD="ADD"; H_DEL="DEL"; H_CHG="CHANGE"; H_FILE="FILE" }
  else            { H_ST="状態";   H_ADD="追加"; H_DEL="削除"; H_CHG="変化量"; H_FILE="ファイル" }
}
function rep(s, n,   i, o) { o = ""; for (i = 0; i < n; i++) o = o s; return o }
# 表示幅 (全角=2桁) を考慮したパディング
function dw(s,   i, n, w, c) {
  if (!MB) return length(s)
  n = length(s); w = 0
  for (i = 1; i <= n; i++) { c = substr(s, i, 1); w += (c ~ WIDE) ? 2 : 1 }
  return w
}
function dpad(s, n,   p)  { p = n - dw(s); if (p < 0) p = 0; return s rep(" ", p) }
function dlpad(s, n,   p) { p = n - dw(s); if (p < 0) p = 0; return rep(" ", p) s }
function rule(ch) { return rep(ch, W) }
function stlabel(c) {
  if (ascii == 1) {
    if (c=="M") return "MOD "; if (c=="A") return "ADD "; if (c=="D") return "DEL "
    if (c=="R") return "REN "; if (c=="C") return "CPY "; if (c=="T") return "TYP "
    if (c=="U") return "UNM "; return "??? "
  }
  if (c=="M") return "変更"; if (c=="A") return "追加"; if (c=="D") return "削除"
  if (c=="R") return "改名"; if (c=="C") return "複製"; if (c=="T") return "型変"
  if (c=="U") return "競合"; return "不明"
}
function stcolor(c) {
  if (c=="A") return GRN; if (c=="D") return RED; if (c=="M") return YEL
  if (c=="R" || c=="C") return CYN; if (c=="U") return MAG; return ""
}
function bar(a, d, mx,   tot, blocks, ab, db, s) {
  tot = a + d
  if (mx <= 0 || tot <= 0) return GRY rep(DOT, 10) R
  blocks = int(tot * 10.0 / mx + 0.999)
  if (blocks < 1) blocks = 1; if (blocks > 10) blocks = 10
  ab = int(blocks * a / tot + 0.5); if (ab > blocks) ab = blocks
  db = blocks - ab
  s = GRN rep(BLK, ab) RED rep(BLK, db) GRY rep(DOT, 10 - blocks) R
  return s
}
function pad(s, n,   l) { l = length(s); if (l >= n) return s; return s rep(" ", n - l) }
function lpad(s, n,   l) { l = length(s); if (l >= n) return s; return rep(" ", n - l) s }
function trunc(s) { if (maxw > 0 && length(s) > maxw) return substr(s, 1, maxw) " ..."; return s }

$1 == "META"   { nmeta++; mk[nmeta] = $2; mv[nmeta] = $3; next }
$1 == "FILE"   {
  nfile++
  fidx[nfile] = $2 + 0; fst[nfile] = $3; fcode[nfile] = $4
  fadd[nfile] = $5 + 0; fdel[nfile] = $6 + 0
  fold[nfile] = $7; fnew[nfile] = $8; fbin[nfile] = $9 + 0; fsim[nfile] = $10
  byidx[$2 + 0] = nfile
  tadd += $5 + 0; tdel += $6 + 0
  if ($5 + $6 > maxchg) maxchg = $5 + $6
  if (fbin[nfile]) nbin++
  cnt[$3]++
  next
}
$1 == "COMMIT" { ncommit++; ch[ncommit] = $2; cd[ncommit] = $3; ca[ncommit] = $4; cs[ncommit] = $5; next }
$1 == "LINE"   { if (!printed) header(); detail(); next }

function header(   i, k) {
  printed = 1
  printf "%s%s%s\n", CYN, rule(HL), R
  printf "%s%s  Git 差分レポート / Git Diff Report%s\n", B CYN, "", R
  printf "%s%s%s\n", CYN, rule(HL), R
  print ""
  printf " %s[ 実行条件 ]%s\n", B YEL, R
  for (i = 1; i <= nmeta; i++) printf "   %s%s%s : %s\n", GRY, dpad(mk[i], 20), R, mv[i]
  print ""
  printf " %s[ 差分サマリ ]%s\n", B YEL, R
  printf "   %s : %s%d%s 件\n", dpad("変更ファイル数", 20), B, nfile, R
  printf "   %s : %s+%d%s 行\n", dpad("追加行数", 20), GRN B, tadd, R
  printf "   %s : %s-%d%s 行\n", dpad("削除行数", 20), RED B, tdel, R
  printf "   %s : %d 行\n", dpad("差引行数", 20), tadd - tdel
  s = ""
  for (k in cnt) s = s sprintf("%s%s(%s)=%d%s  ", stcolor(k), stlabel(k), k, cnt[k], R)
  if (s != "") printf "   %s : %s\n", dpad("状態の内訳", 20), s
  if (nbin > 0) printf "   %s : %d 件\n", dpad("バイナリファイル", 20), nbin
  print ""
  if (nfile > 0) {
    printf " %s[ ファイル別サマリ ]%s\n", B YEL, R
    printf "   %s%s%s\n", GRY, rep(HL, W - 3), R
    printf "   %s%s %s %s %s %s %s%s\n", B, dlpad("No", 4), dpad(H_ST, 8), \
      dlpad(H_ADD, 7), dlpad(H_DEL, 7), dpad(H_CHG, 10), H_FILE, R
    printf "   %s%s%s\n", GRY, rep(HL, W - 3), R
    for (i = 1; i <= nfile; i++) {
      nm = fnew[i]; if (fst[i] == "D") nm = fold[i]
      if ((fst[i] == "R" || fst[i] == "C") && fold[i] != fnew[i]) nm = fold[i] " " AR " " fnew[i]
      bs = fbin[i] ? (ascii == 1 ? " [BINARY]" : " [バイナリ]") : ""
      printf "   %4d %s%s%s %s%s%s %s%s%s %s %s%s\n", i, \
        stcolor(fst[i]), dpad(stlabel(fst[i]) " (" fst[i] ")", 8), R, \
        GRN, lpad("+" fadd[i], 7), R, RED, lpad("-" fdel[i], 7), R, \
        bar(fadd[i], fdel[i], maxchg), nm, bs
    }
    printf "   %s%s%s\n", GRY, rep(HL, W - 3), R
    print ""
  }
  if (ncommit > 0) {
    printf " %s[ 対象コミット一覧 ] (%d 件)%s\n", B YEL, ncommit, R
    for (i = 1; i <= ncommit; i++)
      printf "   %s%-10s%s %s%s%s  %s  %s\n", MAG, ch[i], R, GRY, cd[i], R, ca[i], cs[i]
    print ""
  }
  if (summary_only == 1 || nfile == 0) return
  printf " %s[ 差分明細 ]%s\n", B YEL, R
  printf " %s凡例: %s+ 追加行%s / %s- 削除行%s / 空白 変更なし(前後の文脈)%s\n", GRY, GRN, GRY, RED, GRY, R
  print ""
}

function filehead(idx,   i, nm, ttl) {
  i = byidx[idx]
  if (i == "") { printf "%s%s [%d] (情報なし)%s\n", B YEL, TL, idx, R; return }
  nm = fnew[i]; if (fst[i] == "D") nm = fold[i]
  ttl = sprintf("[%d/%d] %s", i, nfile, nm)
  printf "%s%s%s %s%s%s\n", CYN, TL, rep(HL, 2), B, ttl, R
  if ((fst[i] == "R" || fst[i] == "C") && fold[i] != fnew[i])
    printf "%s%s%s   旧: %s  %s  新: %s\n", CYN, VL, R, fold[i], AR, fnew[i]
  printf "%s%s%s   状態: %s%s (%s)%s   追加: %s+%d%s  削除: %s-%d%s%s\n", \
    CYN, VL, R, stcolor(fst[i]), stlabel(fst[i]), fcode[i], R, \
    GRN, fadd[i], R, RED, fdel[i], R, (fbin[i] ? "   [バイナリ]" : "")
  printf "%s%s%s\n", CYN, VL, R
}

function detail(   idx, kind, ol, nl, txt, i, mark, col) {
  if (summary_only == 1) return
  idx = $2 + 0
  if (idx != curfile) {
    if (curfile >= 0) { printf "%s%s%s%s\n\n", CYN, BLc, rep(HL, 4), R }
    filehead(idx); curfile = idx; shown = 0
  }
  kind = $6
  if (maxl > 0 && shown >= maxl) {
    if (shown == maxl) { printf "%s%s%s   %s... 表示上限 (%d 行) に達しました。全内容は出力ファイルをご確認ください。%s\n", CYN, VL, R, GRY, maxl, R; shown++ }
    return
  }
  if (kind == "hunk") {
    txt = $7; ol = $8 + 0; oc = $9 + 0; nl = $10 + 0; nc = $11 + 0
    printf "%s%s%s %s@@ ハンク%-3d 旧: %d行目から%d行 %s 新: %d行目から%d行 @@%s%s\n", \
      CYN, VL, R, B BLU, $3 + 0, ol, oc, AR, nl, nc, (txt != "" ? "  " txt : ""), R
    shown++
    return
  }
  if (kind == "meta" || kind == "note" || kind == "bin") {
    printf "%s%s%s        %s%s%s\n", CYN, VL, R, GRY, $7, R
    shown++
    return
  }
  ol = $4; nl = $5; txt = trunc($7)
  if (kind == "add")      { mark = "+"; col = GRN }
  else if (kind == "del") { mark = "-"; col = RED }
  else                    { mark = " "; col = "" }
  printf "%s%s%s %s%6s%s %s %s%6s%s %s %s%s %s%s\n", \
    CYN, VL, R, GRY, ol, R, VL, GRY, nl, R, VL, col, mark, txt, R
  shown++
}

END {
  if (!printed) header()
  if (curfile >= 0) printf "%s%s%s%s\n", CYN, BLc, rep(HL, 4), R
  if (nfile == 0) {
    print ""
    printf " %s%s 差分はありません。(比較対象の内容は同一です)%s\n", B GRN, (ascii == 1 ? "[OK]" : "✓"), R
    print ""
  }
  printf "%s%s%s\n", CYN, rule(HL), R
}
AWKEOF

#--- 4) Markdown レポートの描画 -----------------------------------------------
cat >"$TMPD/md.awk" <<'AWKEOF'
BEGIN {
  US = sprintf("%c", 31); FS = US
  # 差分本文に ``` を含むファイル(Markdown 等)でも壊れないよう 4 個のフェンスを使う
  FENCE = "````"
  BLK = "▇"; DOT = "·"; AR = "→"
  ORDER = "M A D R C T U"
  nfile = 0; ncommit = 0; nmeta = 0; printed = 0; curfile = -1; shown = 0
  mdmode = "none"; secno = 0
}
function rep(s, n,   i, o) { o = ""; for (i = 0; i < n; i++) o = o s; return o }
# 表のセル用エスケープ (縦棒は表の区切りとみなされるため退避)
function esc(s) { gsub(/\r/, "", s); gsub(/\|/, "\\\\|", s); return s }
# インラインコード (内部のバッククォート数に応じて区切りを伸ばす)
function ic(s,   i, c, run, m, d) {
  if (s == "") return ""
  run = 0; m = 0
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "`") { run++; if (run > m) m = run } else run = 0
  }
  d = rep("`", m + 1)
  if (substr(s, 1, 1) == "`" || substr(s, length(s), 1) == "`") return d " " s " " d
  return d s d
}
# 出力モードの切替 (none / fence / quote) — 前のブロックを正しく閉じる
function setmode(m) {
  if (mdmode == m) return
  if (mdmode == "fence")      { print FENCE; print "" }
  else if (mdmode == "quote") { print "" }
  mdmode = m
  if (m == "fence") print FENCE "diff"
}
function sec(t) { setmode("none"); secno++; printf "## %d. %s\n\n", secno, t }
function stlabel(c) {
  if (c=="M") return "変更"; if (c=="A") return "追加"; if (c=="D") return "削除"
  if (c=="R") return "改名"; if (c=="C") return "複製"; if (c=="T") return "型変更"
  if (c=="U") return "未解決(競合)"; return "不明"
}
function bar(a, d, mx,   tot, blocks, ab, db) {
  tot = a + d
  if (mx <= 0 || tot <= 0) return rep(DOT, 10)
  blocks = int(tot * 10.0 / mx + 0.999)
  if (blocks < 1) blocks = 1; if (blocks > 10) blocks = 10
  ab = int(blocks * a / tot + 0.5); if (ab > blocks) ab = blocks
  db = blocks - ab
  return rep(BLK, ab) rep(BLK, db) rep(DOT, 10 - blocks)
}

$1 == "META"   { nmeta++; mk[nmeta] = $2; mv[nmeta] = $3; next }
$1 == "FILE"   {
  nfile++
  fst[nfile] = $3; fcode[nfile] = $4; fadd[nfile] = $5 + 0; fdel[nfile] = $6 + 0
  fold[nfile] = $7; fnew[nfile] = $8; fbin[nfile] = $9 + 0; fsim[nfile] = $10
  byidx[$2 + 0] = nfile
  tadd += $5 + 0; tdel += $6 + 0
  if ($5 + $6 > maxchg) maxchg = $5 + $6
  if (fbin[nfile]) nbin++
  cnt[$3]++
  next
}
$1 == "COMMIT" { ncommit++; ch[ncommit] = $2; cd[ncommit] = $3; ca[ncommit] = $4; cs[ncommit] = $5; next }
$1 == "LINE"   { if (!printed) header(); detail(); next }

function header(   i, k, n, s, nm, O) {
  printed = 1
  print "# Git 差分レポート"
  print ""
  print "`git-diff-helper.sh` が生成した Git 差分レポートです。"
  print ""
  sec("実行条件")
  print "| 項目 | 内容 |"
  print "| :--- | :--- |"
  for (i = 1; i <= nmeta; i++) {
    if (mk[i] ~ /コマンド|リポジトリ|ブランチ|HEAD|パス指定/)
      printf "| %s | %s |\n", esc(mk[i]), ic(esc(mv[i]))
    else
      printf "| %s | %s |\n", esc(mk[i]), esc(mv[i])
  }
  print ""

  sec("差分サマリ")
  print "| 項目 | 値 |"
  print "| :--- | ---: |"
  printf "| 変更ファイル数 | %d 件 |\n", nfile
  printf "| 追加行数 | +%d 行 |\n", tadd
  printf "| 削除行数 | -%d 行 |\n", tdel
  printf "| 差引行数 | %d 行 |\n", tadd - tdel
  if (nbin > 0) printf "| バイナリファイル | %d 件 |\n", nbin
  print ""
  s = ""; n = split(ORDER, O, " ")
  for (i = 1; i <= n; i++) {
    k = O[i]
    if (cnt[k] > 0) s = s (s == "" ? "" : " / ") "**" stlabel(k) " (" k ")** " cnt[k] " 件"
  }
  if (s != "") { print "状態の内訳: " s; print "" }

  if (nfile > 0) {
    sec("ファイル別サマリ")
    print "| No | 状態 | 追加 | 削除 | 変化量 | ファイル |"
    print "| ---: | :--- | ---: | ---: | :--- | :--- |"
    for (i = 1; i <= nfile; i++) {
      nm = fnew[i]; if (fst[i] == "D") nm = fold[i]
      if ((fst[i] == "R" || fst[i] == "C") && fold[i] != fnew[i])
        nm = fold[i] " " AR " " fnew[i]
      printf "| %d | %s (%s) | +%d | -%d | `%s` | %s%s |\n", i, stlabel(fst[i]), fst[i], \
        fadd[i], fdel[i], bar(fadd[i], fdel[i], maxchg), ic(esc(nm)), (fbin[i] ? " (バイナリ)" : "")
    }
    print ""
  }

  if (ncommit > 0) {
    sec("対象コミット一覧")
    print "| No | コミット | 日時 | 作成者 | 件名 |"
    print "| ---: | :--- | :--- | :--- | :--- |"
    for (i = 1; i <= ncommit; i++)
      printf "| %d | %s | %s | %s | %s |\n", i, ic(ch[i]), esc(cd[i]), esc(ca[i]), esc(cs[i])
    print ""
  }

  if (summary_only == 1 || nfile == 0) return
  sec("差分明細")
  print "凡例: `+` 追加行 / `-` 削除行 / 先頭空白 変更なし(前後の文脈)"
  print ""
}

function filehead(idx,   i, nm) {
  i = byidx[idx]
  setmode("none")
  if (i == "") { printf "### [%d] (情報なし)\n\n", idx; return }
  nm = fnew[i]; if (fst[i] == "D") nm = fold[i]
  printf "### [%d/%d] %s\n\n", i, nfile, ic(nm)
  printf "- **状態**: %s (%s)\n", stlabel(fst[i]), fcode[i]
  printf "- **増減**: 追加 +%d 行 / 削除 -%d 行\n", fadd[i], fdel[i]
  if ((fst[i] == "R" || fst[i] == "C") && fold[i] != fnew[i])
    printf "- **旧 → 新**: %s %s %s\n", ic(fold[i]), AR, ic(fnew[i])
  if (fbin[i]) print "- **バイナリファイル** (内容の差分は表示できません)"
  print ""
}

function detail(   idx, kind, ol, nl, txt, mark) {
  if (summary_only == 1) return
  idx = $2 + 0
  if (idx != curfile) { filehead(idx); curfile = idx; shown = 0 }
  kind = $6
  if (maxl > 0 && shown >= maxl) {
    if (shown == maxl) {
      setmode("none")
      printf "> 表示上限 (%d 行) に達したため、以降は省略しました。全内容はテキスト/Excel 出力をご確認ください。\n\n", maxl
      shown++
    }
    return
  }
  if (kind == "hunk") {
    setmode("none")
    printf "**@@ ハンク%d — 旧: %d 行目から %d 行 %s 新: %d 行目から %d 行 @@**%s\n\n", \
      $3 + 0, $8, $9, AR, $10, $11, ($7 != "" ? "  " ic($7) : "")
    setmode("fence")
    shown++
    return
  }
  if (kind == "meta" || kind == "note" || kind == "bin") {
    setmode("quote")
    print "> " $7
    shown++
    return
  }
  ol = $4; nl = $5; txt = $7
  if (kind == "add")      mark = "+"
  else if (kind == "del") mark = "-"
  else                    mark = " "
  setmode("fence")
  if (linenos == 1) printf "%s%5s %5s | %s\n", mark, ol, nl, txt
  else              printf "%s%s\n", mark, txt
  shown++
}

END {
  if (!printed) header()
  setmode("none")
  if (nfile == 0) {
    print "> **差分はありません。** 比較対象の内容は同一です。"
    print ""
  }
}
AWKEOF

#--- 5) Excel(xlsx) 生成 ------------------------------------------------------
cat >"$TMPD/xlsx.awk" <<'AWKEOF'
BEGIN {
  US = sprintf("%c", 31); FS = US
  CTRL = "["; for (i = 1; i <= 8; i++) CTRL = CTRL sprintf("%c", i)
  CTRL = CTRL sprintf("%c%c", 11, 12)
  for (i = 14; i <= 31; i++) CTRL = CTRL sprintf("%c", i)
  CTRL = CTRL "]"
  S3 = out "/xl/worksheets/sheet3.rows"
  r3 = 0; nfile = 0; ncommit = 0; nmeta = 0; nline = 0; over = 0
  hdr3()
}
function xesc(s) {
  gsub(CTRL, "", s)
  gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s)
  gsub(/"/, "\\&quot;", s)
  if (length(s) > 32000) s = substr(s, 1, 32000) " …(切り詰め)"
  return s
}
function colref(n,   s, r) { s = ""; while (n > 0) { r = (n - 1) % 26; s = sprintf("%c", 65 + r) s; n = int((n - 1) / 26) } return s }
function xf(k, t) {
  if (k == "hdr")   return 2
  if (k == "title") return 3
  if (k == "label") return 4
  if (k == "add")   return (t == "n") ? 10 : 9
  if (k == "del")   return (t == "n") ? 12 : 11
  if (k == "hunk")  return (t == "n") ? 14 : 13
  if (k == "meta")  return (t == "n") ? 16 : 15
  if (k == "mono")  return (t == "n") ? 8 : 7
  return (t == "n") ? 6 : 5
}
function cell(row, col, k, t, v,   ref, s) {
  ref = colref(col) row; s = xf(k, t)
  if (v == "") return "<c r=\"" ref "\" s=\"" s "\"/>"
  if (t == "n" && v ~ /^-?[0-9]+$/) return "<c r=\"" ref "\" s=\"" s "\"><v>" v "</v></c>"
  return "<c r=\"" ref "\" s=\"" s "\" t=\"inlineStr\"><is><t xml:space=\"preserve\">" xesc(v) "</t></is></c>"
}
function hdr3(   c) {
  c = ""
  r3++
  c = c cell(r3, 1, "hdr", "s", "No")
  c = c cell(r3, 2, "hdr", "s", "ファイルNo")
  c = c cell(r3, 3, "hdr", "s", "ファイル")
  c = c cell(r3, 4, "hdr", "s", "ハンク")
  c = c cell(r3, 5, "hdr", "s", "旧行番号")
  c = c cell(r3, 6, "hdr", "s", "新行番号")
  c = c cell(r3, 7, "hdr", "s", "区分")
  c = c cell(r3, 8, "hdr", "s", "記号")
  c = c cell(r3, 9, "hdr", "s", "内容")
  print "<row r=\"" r3 "\" ht=\"22\" customHeight=\"1\">" c "</row>" > S3
}
function stlabel(c) {
  if (c=="M") return "変更"; if (c=="A") return "追加"; if (c=="D") return "削除"
  if (c=="R") return "改名"; if (c=="C") return "複製"; if (c=="T") return "型変更"
  if (c=="U") return "未解決(競合)"; return "不明"
}
function kindlabel(k) {
  if (k=="add")  return "追加行"
  if (k=="del")  return "削除行"
  if (k=="ctx")  return "変更なし"
  if (k=="hunk") return "ハンク見出し"
  if (k=="meta") return "属性情報"
  if (k=="bin")  return "バイナリ"
  return "備考"
}

$1 == "META"   { nmeta++; mk[nmeta] = $2; mv[nmeta] = $3; next }
$1 == "FILE"   {
  nfile++
  fst[nfile] = $3; fcode[nfile] = $4; fadd[nfile] = $5 + 0; fdel[nfile] = $6 + 0
  fold[nfile] = $7; fnew[nfile] = $8; fbin[nfile] = $9 + 0; fsim[nfile] = $10
  byidx[$2 + 0] = nfile
  tadd += $5 + 0; tdel += $6 + 0
  next
}
$1 == "COMMIT" { ncommit++; ch[ncommit] = $2; cd[ncommit] = $3; ca[ncommit] = $4; cs[ncommit] = $5; next }
$1 == "LINE" {
  nline++
  if (maxrows > 0 && r3 > maxrows) { over++; next }
  i = byidx[$2 + 0]
  nm = (i == "") ? "" : ((fst[i] == "D") ? fold[i] : fnew[i])
  kind = $6
  if (kind == "hunk") {
    txt = sprintf("@@ 旧 %d行目から%d行  →  新 %d行目から%d行 @@ %s", $8, $9, $10, $11, $7)
    ol = ""; nl = ""; mark = "@@"; k = "hunk"
  } else if (kind == "add") { txt = $7; ol = $4; nl = $5; mark = "+"; k = "add" }
  else if (kind == "del")   { txt = $7; ol = $4; nl = $5; mark = "-"; k = "del" }
  else if (kind == "ctx")   { txt = $7; ol = $4; nl = $5; mark = "";  k = "mono" }
  else                      { txt = $7; ol = ""; nl = ""; mark = "";  k = "meta" }
  r3++
  c = cell(r3, 1, k, "n", r3 - 1)
  c = c cell(r3, 2, k, "n", $2 + 0)
  c = c cell(r3, 3, k, "s", nm)
  c = c cell(r3, 4, k, "n", $3 + 0)
  c = c cell(r3, 5, k, "n", ol)
  c = c cell(r3, 6, k, "n", nl)
  c = c cell(r3, 7, k, "s", kindlabel(kind))
  c = c cell(r3, 8, k, "s", mark)
  c = c cell(r3, 9, k, "s", txt)
  print "<row r=\"" r3 "\">" c "</row>" > S3
  next
}

END {
  #---------------- sheet1: サマリ ----------------
  f = out "/xl/worksheets/sheet1.rows"; r = 0
  r++; print "<row r=\"" r "\" ht=\"24\" customHeight=\"1\">" cell(r,1,"title","s","Git 差分レポート") "</row>" > f
  r++; print "<row r=\"" r "\"/>" > f
  r++; print "<row r=\"" r "\">" cell(r,1,"hdr","s","項目") cell(r,2,"hdr","s","内容") "</row>" > f
  for (i = 1; i <= nmeta; i++) {
    r++
    print "<row r=\"" r "\">" cell(r,1,"label","s",mk[i]) cell(r,2,"plain","s",mv[i]) "</row>" > f
  }
  r++; print "<row r=\"" r "\"/>" > f
  r++; print "<row r=\"" r "\">" cell(r,1,"hdr","s","集計") cell(r,2,"hdr","s","値") "</row>" > f
  r++; print "<row r=\"" r "\">" cell(r,1,"label","s","変更ファイル数") cell(r,2,"plain","n",nfile) "</row>" > f
  r++; print "<row r=\"" r "\">" cell(r,1,"label","s","追加行数") cell(r,2,"add","n",tadd) "</row>" > f
  r++; print "<row r=\"" r "\">" cell(r,1,"label","s","削除行数") cell(r,2,"del","n",tdel) "</row>" > f
  r++; print "<row r=\"" r "\">" cell(r,1,"label","s","差引行数") cell(r,2,"plain","n",tadd - tdel) "</row>" > f
  r++; print "<row r=\"" r "\">" cell(r,1,"label","s","差分明細 行数") cell(r,2,"plain","n",nline) "</row>" > f
  r++; print "<row r=\"" r "\">" cell(r,1,"label","s","対象コミット数") cell(r,2,"plain","n",ncommit) "</row>" > f
  if (nfile == 0) {
    r++; print "<row r=\"" r "\"/>" > f
    r++; print "<row r=\"" r "\">" cell(r,1,"plain","s","差分はありません。比較対象の内容は同一です。") "</row>" > f
  }
  close(f)
  print "1" US r US "3" US "0" US "12" US "70" > (out "/meta1.txt")

  #---------------- sheet2: ファイル一覧 ----------------
  f = out "/xl/worksheets/sheet2.rows"; r = 0
  r++
  c = cell(r,1,"hdr","s","No") cell(r,2,"hdr","s","状態") cell(r,3,"hdr","s","状態コード")
  c = c cell(r,4,"hdr","s","追加行") cell(r,5,"hdr","s","削除行") cell(r,6,"hdr","s","変更行合計")
  c = c cell(r,7,"hdr","s","種別") cell(r,8,"hdr","s","ファイル(新)") cell(r,9,"hdr","s","ファイル(旧)")
  print "<row r=\"" r "\" ht=\"22\" customHeight=\"1\">" c "</row>" > f
  for (i = 1; i <= nfile; i++) {
    r++
    k = (fst[i] == "A") ? "add" : ((fst[i] == "D") ? "del" : "plain")
    c = cell(r,1,k,"n",i) cell(r,2,k,"s",stlabel(fst[i])) cell(r,3,k,"s",fcode[i])
    c = c cell(r,4,k,"n",fadd[i]) cell(r,5,k,"n",fdel[i]) cell(r,6,k,"n",fadd[i] + fdel[i])
    c = c cell(r,7,k,"s",(fbin[i] ? "バイナリ" : "テキスト"))
    c = c cell(r,8,k,"s",fnew[i]) cell(r,9,k,"s",fold[i])
    print "<row r=\"" r "\">" c "</row>" > f
  }
  if (nfile == 0) {
    r++
    print "<row r=\"" r "\">" cell(r,1,"plain","s","差分のあるファイルはありません。") "</row>" > f
  }
  close(f)
  print "2" US r US "9" US "1" US "6" US "20" > (out "/meta2.txt")

  #---------------- sheet3: 差分明細 ----------------
  if (over > 0) {
    r3++
    print "<row r=\"" r3 "\">" cell(r3,1,"meta","s","※ 出力上限(" maxrows " 行)を超えたため、以降 " over " 行を省略しました。") "</row>" > S3
  }
  if (nline == 0) {
    r3++
    print "<row r=\"" r3 "\">" cell(r3,1,"plain","s","差分明細はありません。") "</row>" > S3
  }
  close(S3)
  print "3" US r3 US "9" US "1" US "6" US "20" > (out "/meta3.txt")

  #---------------- sheet4: コミット履歴 ----------------
  f = out "/xl/worksheets/sheet4.rows"; r = 0
  r++
  c = cell(r,1,"hdr","s","No") cell(r,2,"hdr","s","コミット") cell(r,3,"hdr","s","日時")
  c = c cell(r,4,"hdr","s","作成者") cell(r,5,"hdr","s","件名")
  print "<row r=\"" r "\" ht=\"22\" customHeight=\"1\">" c "</row>" > f
  for (i = 1; i <= ncommit; i++) {
    r++
    c = cell(r,1,"plain","n",i) cell(r,2,"mono","s",ch[i]) cell(r,3,"plain","s",cd[i])
    c = c cell(r,4,"plain","s",ca[i]) cell(r,5,"plain","s",cs[i])
    print "<row r=\"" r "\">" c "</row>" > f
  }
  if (ncommit == 0) {
    r++
    print "<row r=\"" r "\">" cell(r,1,"plain","s","このモードでは対象コミットの一覧はありません。") "</row>" > f
  }
  close(f)
  print "4" US r US "5" US "1" US "5" US "20" > (out "/meta4.txt")
}
AWKEOF

#--- 6) CSV 生成 --------------------------------------------------------------
cat >"$TMPD/csv.awk" <<'AWKEOF'
BEGIN {
  US = sprintf("%c", 31); FS = US
  BOM = sprintf("%c%c%c", 239, 187, 191)
  F1 = out "_1_サマリ.csv"; F2 = out "_2_ファイル一覧.csv"
  F3 = out "_3_差分明細.csv"; F4 = out "_4_コミット履歴.csv"
  printf "%s", BOM > F1; printf "%s", BOM > F2; printf "%s", BOM > F3; printf "%s", BOM > F4
  print q("項目") "," q("内容") > F1
  print q("No") "," q("状態") "," q("状態コード") "," q("追加行") "," q("削除行") "," q("変更行合計") "," q("種別") "," q("ファイル(新)") "," q("ファイル(旧)") > F2
  print q("No") "," q("ファイルNo") "," q("ファイル") "," q("ハンク") "," q("旧行番号") "," q("新行番号") "," q("区分") "," q("記号") "," q("内容") > F3
  print q("No") "," q("コミット") "," q("日時") "," q("作成者") "," q("件名") > F4
  n3 = 0
}
function q(s) { gsub(/"/, "\"\"", s); return "\"" s "\"" }
function stlabel(c) {
  if (c=="M") return "変更"; if (c=="A") return "追加"; if (c=="D") return "削除"
  if (c=="R") return "改名"; if (c=="C") return "複製"; if (c=="T") return "型変更"
  if (c=="U") return "未解決(競合)"; return "不明"
}
function kindlabel(k) {
  if (k=="add") return "追加行"; if (k=="del") return "削除行"; if (k=="ctx") return "変更なし"
  if (k=="hunk") return "ハンク見出し"; if (k=="meta") return "属性情報"; if (k=="bin") return "バイナリ"
  return "備考"
}
$1 == "META" { print q($2) "," q($3) > F1; next }
$1 == "FILE" {
  nfile++; fst[nfile]=$3; fold[nfile]=$7; fnew[nfile]=$8; byidx[$2+0]=nfile
  tadd += $5 + 0; tdel += $6 + 0
  print q(nfile) "," q(stlabel($3)) "," q($4) "," q($5) "," q($6) "," q($5 + $6) "," q($9 + 0 ? "バイナリ" : "テキスト") "," q($8) "," q($7) > F2
  next
}
$1 == "COMMIT" { ncommit++; print q(ncommit) "," q($2) "," q($3) "," q($4) "," q($5) > F4; next }
$1 == "LINE" {
  i = byidx[$2 + 0]
  nm = (i == "") ? "" : ((fst[i] == "D") ? fold[i] : fnew[i])
  kind = $6
  if (kind == "hunk") { txt = sprintf("@@ 旧 %d行目から%d行 → 新 %d行目から%d行 @@ %s", $8,$9,$10,$11,$7); ol=""; nl=""; mark="@@" }
  else if (kind == "add") { txt=$7; ol=$4; nl=$5; mark="+" }
  else if (kind == "del") { txt=$7; ol=$4; nl=$5; mark="-" }
  else if (kind == "ctx") { txt=$7; ol=$4; nl=$5; mark="" }
  else { txt=$7; ol=""; nl=""; mark="" }
  n3++
  print q(n3) "," q($2 + 0) "," q(nm) "," q($3 + 0) "," q(ol) "," q(nl) "," q(kindlabel(kind)) "," q(mark) "," q(txt) > F3
  next
}
END {
  print q("変更ファイル数") "," q(nfile + 0) > F1
  print q("追加行数") "," q(tadd + 0) > F1
  print q("削除行数") "," q(tdel + 0) > F1
  print q("差引行数") "," q(tadd - tdel) > F1
  print q("対象コミット数") "," q(ncommit + 0) > F1
}
AWKEOF
}

#==============================================================================
# データ収集 → report.dat
#==============================================================================
collect_diff_outputs() {
  git_diff --name-status -z | tr '\000' '\n' > "$TMPD/namestatus.txt" \
    || die "git diff --name-status の実行に失敗しました。"
  git_diff --numstat -z | tr '\000' '\n' > "$TMPD/numstat.txt" \
    || die "git diff --numstat の実行に失敗しました。"
  git_diff "--unified=${CONTEXT}" > "$TMPD/current.patch" \
    || die "git diff のパッチ取得に失敗しました。"
}

selected_commit_parent() {
  local headers field value
  headers="$("${GIT[@]}" cat-file -p "$1")" || die "コミットの読み取りに失敗しました: $1"
  SELECTED_PARENT=""
  # shallow 境界を初回コミットと誤認しないよう、オブジェクトの親を直接調べる。
  while IFS=' ' read -r field value; do
    [[ -n "$field" ]] || break
    if [[ "$field" == "parent" ]]; then SELECTED_PARENT="$value"; break; fi
  done <<< "$headers"
  if [[ -n "$SELECTED_PARENT" ]]; then
    verify_ref "$SELECTED_PARENT" \
      || die "親コミットが取得できません: $1 (親: $SELECTED_PARENT)。不足する履歴を取得してください。"
  else
    SELECTED_PARENT="$("${GIT[@]}" hash-object -t tree --stdin </dev/null)" \
      || die "空ツリーの識別子を取得できません。"
  fi
}

collect_selected_data() {
  local oid records="$TMPD/selected.dat"
  : > "$records" || die "作業ファイルを作成できません。"
  : > "$TMPD/patch.txt" || die "パッチファイルを作成できません。"
  mkdir "$TMPD/selected-lines" || die "明細の作業ディレクトリを作成できません。"
  for oid in "${SELECTED_COMMITS[@]}"; do
    selected_commit_parent "$oid"
    RANGE=("$SELECTED_PARENT" "$oid")
    collect_diff_outputs
    printf 'SELECT%s%s%s%s\n' "$US" "$oid" "$US" "$SELECTED_PARENT" >> "$records" \
      || die "選択コミット情報の保存に失敗しました。"
    "${GIT[@]}" --no-pager log -1 --no-color --no-decorate --no-notes \
      --no-show-signature --no-patch --date=format:'%Y-%m-%d %H:%M:%S %z' \
      --format="COMMIT${US}%H${US}%ad${US}%an${US}%s" "$oid" -- >> "$records" \
      || die "選択コミットの履歴取得に失敗しました: $oid"
    "${AWK[@]}" -f "$TMPD/files.awk" "$TMPD/namestatus.txt" "$TMPD/numstat.txt" >> "$records" \
      || die "選択コミットのファイル一覧の解析に失敗しました: $oid"
    "${AWK[@]}" -f "$TMPD/patch.awk" "$TMPD/current.patch" >> "$records" \
      || die "選択コミットのパッチ解析に失敗しました: $oid"
    printf '# commit: %s\n# parent: %s\n' "$oid" "$SELECTED_PARENT" >> "$TMPD/patch.txt" \
      || die "パッチの見出しの保存に失敗しました。"
    cat "$TMPD/current.patch" >> "$TMPD/patch.txt" || die "パッチの保存に失敗しました。"
  done
  "${AWK[@]}" -v dir="$TMPD/selected-lines" -f "$TMPD/selected.awk" "$records" > "$TMPD/changes.dat" \
    || die "選択コミットの集約に失敗しました。"
}

collect_data() {
  if [[ "$MODE" == "multi" ]]; then
    collect_selected_data
  else
    collect_diff_outputs
    cp "$TMPD/current.patch" "$TMPD/patch.txt" || die "パッチの保存に失敗しました。"
    "${AWK[@]}" -f "$TMPD/files.awk" "$TMPD/namestatus.txt" "$TMPD/numstat.txt" > "$TMPD/changes.dat" \
      || die "ファイル一覧の解析に失敗しました。"
    if [[ -n "$LOG_RANGE" ]]; then
      "${GIT[@]}" log --date=format:'%Y-%m-%d %H:%M:%S' \
        --format="COMMIT${US}%h${US}%ad${US}%an${US}%s" "$LOG_RANGE" >> "$TMPD/changes.dat" \
        || die "コミット履歴の取得に失敗しました。"
    fi
    "${AWK[@]}" -f "$TMPD/patch.awk" "$TMPD/patch.txt" >> "$TMPD/changes.dat" \
      || die "パッチの解析に失敗しました。"
  fi

  {
    # --- META ---
    printf 'META%s%s%s%s\n' "$US" "実行日時"       "$US" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'META%s%s%s%s\n' "$US" "リポジトリ"     "$US" "$REPO_ROOT"
    printf 'META%s%s%s%s\n' "$US" "現在のブランチ" "$US" "$CUR_BRANCH"
    printf 'META%s%s%s%s\n' "$US" "現在の HEAD"    "$US" "$HEAD_INFO"
    if [[ -n "$HISTORY_BRANCH" ]]; then
      printf 'META%s%s%s%s\n' "$US" "履歴のブランチ" "$US" "$HISTORY_BRANCH"
      printf 'META%s%s%s%s\n' "$US" "履歴の先端"     "$US" "$HISTORY_TIP"
    fi
    printf 'META%s%s%s%s\n' "$US" "モード"         "$US" "$MODE"
    printf 'META%s%s%s%s\n' "$US" "比較内容"       "$US" "$MODE_DESC"
    if [[ "$MODE" == "multi" ]]; then
      printf 'META%s%s%s%s\n' "$US" "選択コミット数" "$US" "${#SELECTED_COMMITS[@]}"
      printf 'META%s%s%s%s\n' "$US" "集約単位" "$US" "変更後のパス (削除時は変更前)。状態が混在する場合は変更 (M)。"
    fi
    printf 'META%s%s%s%s\n' "$US" "比較元 (左)"    "$US" "$SIDE_L"
    printf 'META%s%s%s%s\n' "$US" "比較先 (右)"    "$US" "$SIDE_R"
    printf 'META%s%s%s%s\n' "$US" "説明"           "$US" "$MODE_NOTE"
    printf 'META%s%s%s%s\n' "$US" "実行コマンド"   "$US" "$DIFF_CMD_DISPLAY"
    printf 'META%s%s%s%s\n' "$US" "コンテキスト行" "$US" "$CONTEXT"
    if ((${#PATHSPEC[@]})); then
      printf 'META%s%s%s%s\n' "$US" "パス指定" "$US" "${PATHSPEC[*]}"
    fi
    if [[ -n "${AHEAD_BEHIND:-}" ]]; then
      local behind ahead
      behind="${AHEAD_BEHIND%% *}"; ahead="${AHEAD_BEHIND##* }"
      printf 'META%s%s%s%s\n' "$US" "リモートとの進み具合" "$US" \
        "リモート側のみ ${behind} コミット / ローカル側のみ ${ahead} コミット"
    fi
    ((IGNORE_SPACE)) && printf 'META%s%s%s%s\n' "$US" "オプション" "$US" "空白差分を無視 (-w)"

    # --- FILE / COMMIT / LINE ---
    cat "$TMPD/changes.dat"
  } | grep -v '^$' > "$TMPD/report.dat" || die "レポートデータの保存に失敗しました。"

  return 0
}

#==============================================================================
# 画面 / テキスト出力
#==============================================================================
render() {  # $1: color(0/1)
  "${AWK[@]}" -v color="$1" -v ascii="$ASCII_FLAG" -v width="$TERM_WIDTH" \
      -v summary_only="$SUMMARY_ONLY" -v maxl="$MAX_LINES" -v maxw=0 \
      -f "$TMPD/render.awk" "$TMPD/report.dat"
}

#==============================================================================
# Markdown 出力
#==============================================================================
render_md() {
  "${AWK[@]}" -v summary_only="$SUMMARY_ONLY" -v maxl="$MAX_LINES" \
      -v linenos="$MD_LINENOS" \
      -f "$TMPD/md.awk" "$TMPD/report.dat"
}

#==============================================================================
# Excel (xlsx) 出力
#==============================================================================
find_zipper() {
  if command -v zip >/dev/null 2>&1; then echo "zip"; return 0; fi
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import zipfile' >/dev/null 2>&1; then echo "python3"; return 0; fi
  if command -v python >/dev/null 2>&1 && python -c 'import zipfile' >/dev/null 2>&1; then echo "python"; return 0; fi
  if command -v jar >/dev/null 2>&1; then echo "jar"; return 0; fi
  echo ""; return 1
}

write_xlsx_static() {
  local b="$1"
  mkdir -p "$b/_rels" "$b/xl/_rels" "$b/xl/worksheets"

  cat >"$b/[Content_Types].xml" <<'EOS'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet3.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet4.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
EOS

  cat >"$b/_rels/.rels" <<'EOS'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
EOS

  cat >"$b/xl/workbook.xml" <<'EOS'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><workbookPr/><sheets><sheet name="サマリ" sheetId="1" r:id="rId1"/><sheet name="ファイル一覧" sheetId="2" r:id="rId2"/><sheet name="差分明細" sheetId="3" r:id="rId3"/><sheet name="コミット履歴" sheetId="4" r:id="rId4"/></sheets></workbook>
EOS

  cat >"$b/xl/_rels/workbook.xml.rels" <<'EOS'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet3.xml"/><Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet4.xml"/><Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
EOS

  cat >"$b/xl/styles.xml" <<'EOS'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="7"><font><sz val="11"/><color rgb="FF000000"/><name val="Meiryo UI"/><family val="3"/></font><font><b/><sz val="11"/><color rgb="FF000000"/><name val="Meiryo UI"/><family val="3"/></font><font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Meiryo UI"/><family val="3"/></font><font><b/><sz val="14"/><color rgb="FF1F4E79"/><name val="Meiryo UI"/><family val="3"/></font><font><sz val="10"/><color rgb="FF000000"/><name val="Consolas"/><family val="3"/></font><font><i/><sz val="10"/><color rgb="FF595959"/><name val="Consolas"/><family val="3"/></font><font><b/><sz val="10"/><color rgb="FF1F4E79"/><name val="Consolas"/><family val="3"/></font></fonts><fills count="7"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF1F4E79"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFE6FFEC"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFFFEBE9"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFDDEBF7"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFF2F2F2"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border><border><left style="thin"><color rgb="FFBFBFBF"/></left><right style="thin"><color rgb="FFBFBFBF"/></right><top style="thin"><color rgb="FFBFBFBF"/></top><bottom style="thin"><color rgb="FFBFBFBF"/></bottom><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="17"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="0" fontId="2" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment vertical="center"/></xf><xf numFmtId="0" fontId="1" fillId="6" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="center"/></xf><xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="center"/></xf><xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment horizontal="right" vertical="center"/></xf><xf numFmtId="0" fontId="4" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="center"/></xf><xf numFmtId="0" fontId="4" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1"><alignment horizontal="right" vertical="center"/></xf><xf numFmtId="0" fontId="4" fillId="3" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="center"/></xf><xf numFmtId="0" fontId="4" fillId="3" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="right" vertical="center"/></xf><xf numFmtId="0" fontId="4" fillId="4" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="center"/></xf><xf numFmtId="0" fontId="4" fillId="4" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="right" vertical="center"/></xf><xf numFmtId="0" fontId="6" fillId="5" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="center"/></xf><xf numFmtId="0" fontId="6" fillId="5" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="right" vertical="center"/></xf><xf numFmtId="0" fontId="5" fillId="6" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="center"/></xf><xf numFmtId="0" fontId="5" fillId="6" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="right" vertical="center"/></xf></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles><dxfs count="0"/><tableStyles count="0" defaultTableStyle="TableStyleMedium2"/></styleSheet>
EOS
}

# シート XML を組み立てる (head + rows + foot)
assemble_sheet() {
  local b="$1" n="$2" rows="$3" ncols="$4" freeze="$5" cols_xml="$6" filter="$7"
  local last; last="$(awk -v n="$ncols" 'BEGIN{s="";while(n>0){r=(n-1)%26;s=sprintf("%c",65+r) s;n=int((n-1)/26)}print s}')"
  local sel=""; [[ "$n" == "1" ]] && sel=' tabSelected="1"'
  {
    printf '%s' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    printf '%s' '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    printf '<dimension ref="A1:%s%s"/>' "$last" "$rows"
    printf '<sheetViews><sheetView%s workbookViewId="0" showGridLines="0">' "$sel"
    if [[ "$freeze" != "0" ]]; then
      printf '<pane ySplit="%s" topLeftCell="A%s" activePane="bottomLeft" state="frozen"/>' "$freeze" "$((freeze + 1))"
      printf '<selection pane="bottomLeft" activeCell="A%s" sqref="A%s"/>' "$((freeze + 1))" "$((freeze + 1))"
    fi
    printf '%s' '</sheetView></sheetViews>'
    printf '%s' '<sheetFormatPr defaultRowHeight="16.5"/>'
    printf '%s' "$cols_xml"
    printf '%s' '<sheetData>'
    cat "$b/xl/worksheets/sheet${n}.rows"
    printf '%s' '</sheetData>'
    if [[ "$filter" == "1" && "$rows" -gt 1 ]]; then
      printf '<autoFilter ref="A1:%s%s"/>' "$last" "$rows"
    fi
    printf '%s' '</worksheet>'
  } > "$b/xl/worksheets/sheet${n}.xml"
  rm -f "$b/xl/worksheets/sheet${n}.rows"
}

make_xlsx() {
  local outfile="$1"
  local b="$TMPD/xlsx"
  rm -rf "$b"; mkdir -p "$b/xl/worksheets"
  write_xlsx_static "$b"

  "${AWK[@]}" -v out="$b" -v maxrows="$EXCEL_MAX_ROWS" -f "$TMPD/xlsx.awk" "$TMPD/report.dat" || {
    err "Excel データの生成に失敗しました。"; return 1; }

  local r1 r2 r3 r4
  r1="$(awk -F"$US" 'NR==1{print $2}' "$b/meta1.txt")"
  r2="$(awk -F"$US" 'NR==1{print $2}' "$b/meta2.txt")"
  r3="$(awk -F"$US" 'NR==1{print $2}' "$b/meta3.txt")"
  r4="$(awk -F"$US" 'NR==1{print $2}' "$b/meta4.txt")"

  assemble_sheet "$b" 1 "$r1" 2 0 \
    '<cols><col min="1" max="1" width="24" customWidth="1"/><col min="2" max="2" width="95" customWidth="1"/></cols>' 0
  assemble_sheet "$b" 2 "$r2" 9 1 \
    '<cols><col min="1" max="1" width="6" customWidth="1"/><col min="2" max="2" width="14" customWidth="1"/><col min="3" max="3" width="12" customWidth="1"/><col min="4" max="6" width="11" customWidth="1"/><col min="7" max="7" width="12" customWidth="1"/><col min="8" max="9" width="55" customWidth="1"/></cols>' 1
  assemble_sheet "$b" 3 "$r3" 9 1 \
    '<cols><col min="1" max="1" width="8" customWidth="1"/><col min="2" max="2" width="10" customWidth="1"/><col min="3" max="3" width="42" customWidth="1"/><col min="4" max="4" width="8" customWidth="1"/><col min="5" max="6" width="11" customWidth="1"/><col min="7" max="7" width="14" customWidth="1"/><col min="8" max="8" width="7" customWidth="1"/><col min="9" max="9" width="120" customWidth="1"/></cols>' 1
  assemble_sheet "$b" 4 "$r4" 5 1 \
    '<cols><col min="1" max="1" width="6" customWidth="1"/><col min="2" max="2" width="14" customWidth="1"/><col min="3" max="3" width="22" customWidth="1"/><col min="4" max="4" width="22" customWidth="1"/><col min="5" max="5" width="80" customWidth="1"/></cols>' 0

  rm -f "$b"/meta?.txt

  zip_package "$b" "$outfile" '[Content_Types].xml' _rels xl || return 1
  [[ -s "$outfile" ]] || { err "xlsx ファイルが生成されませんでした。"; return 1; }
  return 0
}

# ディレクトリを zip 化して xlsx を作る (zip / python3 / python / jar のいずれかを使用)
zip_package() {  # $1 ソースディレクトリ  $2 出力ファイル  $3.. 収録エントリ
  local src="$1" outfile="$2"; shift 2
  local zipper; zipper="$(find_zipper)"
  rm -f "$outfile"
  local absout; absout="$(cd -- "$(dirname -- "$outfile")" && pwd)/$(basename -- "$outfile")"
  (
    cd "$src" || exit 1
    case "$zipper" in
      zip)     zip -q -X -r "$absout" "$@" ;;
      python3) python3 -m zipfile -c "$absout" "$@" ;;
      python)  python  -m zipfile -c "$absout" "$@" ;;
      jar)     jar cfM "$absout" "$@" ;;
      *)       exit 9 ;;
    esac
  )
  local rc=$?
  ((rc == 0)) || { err "xlsx の圧縮に失敗しました (zipper=${zipper:-なし}, rc=$rc)"; return 1; }
  return 0
}

make_csv() {
  local base="$1"
  "${AWK[@]}" -v out="$base" -f "$TMPD/csv.awk" "$TMPD/report.dat"
}

#==============================================================================
# 利用ガイド Excel (使い方マニュアル) の生成
#------------------------------------------------------------------------------
#  ・全シート Meiryo UI フォントで統一
#  ・9 シート構成 (表紙 / セットアップ / モード / オプション / 使用例 /
#                  出力ファイル / レポートの見方 / FAQ / 用語集)
#  ・見出し帯・ゼブラ模様・枠固定・オートフィルタ・印刷設定を付与
#==============================================================================
MAN_LETTERS="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
MAN_S=0
MAN_E=""

man_col() { printf '%s' "${MAN_LETTERS:$(($1 - 1)):1}"; }

# XML エスケープ (結果は MAN_E に格納。サブシェルを使わず高速に処理する)
#   ※ bash 5.2 以降は置換文字列中の素の & が「一致した文字列」を表すため、
#      互換性のため必ず \& の形でエスケープすること。
man_esc() {
  MAN_E="$1"
  MAN_E="${MAN_E//&/\&amp;}"
  MAN_E="${MAN_E//</\&lt;}"
  MAN_E="${MAN_E//>/\&gt;}"
  MAN_E="${MAN_E//\"/\&quot;}"
}

# スタイル名 → cellXfs のインデックス (MAN_Z=1 のときは縞模様用に振替)
man_style() {
  local k="$1"
  if ((MAN_Z)); then
    case "$k" in
      plain)  k="plainz" ;;
      center) k="centerz" ;;
    esac
  fi
  case "$k" in
    title)    MAN_S=1  ;;
    subtitle) MAN_S=2  ;;
    caption)  MAN_S=3  ;;
    hdr)      MAN_S=4  ;;
    sect)     MAN_S=5  ;;
    lead)     MAN_S=6  ;;
    note)     MAN_S=7  ;;
    plain)    MAN_S=8  ;;
    center)   MAN_S=9  ;;
    label)    MAN_S=10 ;;
    key)      MAN_S=11 ;;
    code)     MAN_S=12 ;;
    accent)   MAN_S=13 ;;
    tip)      MAN_S=14 ;;
    good)     MAN_S=15 ;;
    bad)      MAN_S=16 ;;
    gray)     MAN_S=17 ;;
    bold)     MAN_S=18 ;;
    step)     MAN_S=19 ;;
    plainz)   MAN_S=20 ;;
    centerz)  MAN_S=21 ;;
    *)        MAN_S=0  ;;
  esac
}

man_cell() {  # $1 スタイル名  $2 値
  local key="$1" v="$2" ref
  MAN_COL=$((MAN_COL + 1))
  man_style "$key"
  ref="${MAN_LETTERS:$((MAN_COL - 1)):1}${MAN_ROW}"
  if [[ -z "$v" ]]; then
    MAN_BUF+="<c r=\"$ref\" s=\"$MAN_S\"/>"
  elif [[ "$key" != "code" && "$key" != "key" && "$v" =~ ^-?[0-9]+$ ]]; then
    MAN_BUF+="<c r=\"$ref\" s=\"$MAN_S\"><v>$v</v></c>"
  else
    man_esc "$v"
    MAN_BUF+="<c r=\"$ref\" s=\"$MAN_S\" t=\"inlineStr\"><is><t xml:space=\"preserve\">${MAN_E}</t></is></c>"
  fi
}

man_emit_row() {  # $1 行高 ("" なら自動調整)
  if [[ -n "${1:-}" ]]; then
    printf '<row r="%d" ht="%s" customHeight="1">%s</row>\n' "$MAN_ROW" "$1" "$MAN_BUF" >>"$MAN_SHEET"
  else
    printf '<row r="%d">%s</row>\n' "$MAN_ROW" "$MAN_BUF" >>"$MAN_SHEET"
  fi
}

man_row() {  # $1 行高  以降: スタイル 値 スタイル 値 ...
  local ht="$1"; shift
  MAN_ROW=$((MAN_ROW + 1)); MAN_COL=0; MAN_BUF=""
  while (($# >= 2)); do man_cell "$1" "$2"; shift 2; done
  man_emit_row "$ht"
}

# 全列を結合した 1 行 (帯・見出し・注記など。折り返さない短文に使う)
man_span() {  # $1 行高  $2 スタイル  $3 テキスト
  local ht="$1" st="$2" tx="$3" i
  MAN_ROW=$((MAN_ROW + 1)); MAN_COL=0; MAN_BUF=""
  man_cell "$st" "$tx"
  for ((i = 2; i <= MAN_NCOL; i++)); do man_cell "$st" ""; done
  man_emit_row "$ht"
  MAN_MERGE+="<mergeCell ref=\"A${MAN_ROW}:${MAN_LAST}${MAN_ROW}\"/>"
  MAN_NMERGE=$((MAN_NMERGE + 1))
}

man_section() { man_row 7; man_span 27 sect "■ $1"; }
man_tip()     { man_span 24 tip "$1"; }
man_note()    { man_span 20 note "$1"; }

man_head() {  # 表の見出し行 (引数はラベルの並び)
  MAN_ROW=$((MAN_ROW + 1)); MAN_COL=0; MAN_BUF=""; MAN_Z=0
  while (($#)); do man_cell hdr "$1"; shift; done
  man_emit_row 27
  MAN_FILTER_TOP="$MAN_ROW"
}

# 直前の表にオートフィルタを設定する
man_filter() { MAN_FILTER="A${MAN_FILTER_TOP}:${MAN_LAST}${MAN_ROW}"; }

# 直前に出力した行のセルを結合する
man_merge_cur() {  # $1 開始列番号  $2 終了列番号
  local c1="${MAN_LETTERS:$(($1 - 1)):1}" c2="${MAN_LETTERS:$(($2 - 1)):1}"
  MAN_MERGE+="<mergeCell ref=\"${c1}${MAN_ROW}:${c2}${MAN_ROW}\"/>"
  MAN_NMERGE=$((MAN_NMERGE + 1))
}

man_sheet_begin() {  # $1 シート番号  $2 列数  $3 タブ色  $4 cols定義  $5 固定行数
  MAN_IDX="$1"; MAN_NCOL="$2"; MAN_TAB="$3"; MAN_COLS_XML="$4"; MAN_FREEZE="$5"
  MAN_LAST="${MAN_LETTERS:$(($2 - 1)):1}"
  MAN_SHEET="$MANB/xl/worksheets/sheet${1}.rows"; : >"$MAN_SHEET"
  MAN_ROW=0; MAN_COL=0; MAN_BUF=""; MAN_MERGE=""; MAN_NMERGE=0
  MAN_FILTER=""; MAN_FILTER_TOP=1; MAN_Z=0
}

# 表紙帯 (タイトル + サブタイトル + 補足) を出力する
man_banner() {  # $1 タイトル  $2 サブタイトル  $3 補足
  man_span 48 title "  $1"
  man_span 27 subtitle "  $2"
  man_span 22 caption "  $3"
}

man_sheet_end() {
  local n="$MAN_IDX" last="$MAN_LAST" sel=""
  [[ "$n" == "1" ]] && sel=' tabSelected="1"'
  {
    printf '%s' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    printf '%s' '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    printf '<sheetPr><tabColor rgb="%s"/><pageSetUpPr fitToPage="1"/></sheetPr>' "$MAN_TAB"
    printf '<dimension ref="A1:%s%d"/>' "$last" "$MAN_ROW"
    printf '<sheetViews><sheetView%s showGridLines="0" zoomScaleNormal="100" workbookViewId="0">' "$sel"
    if [[ "$MAN_FREEZE" != "0" ]]; then
      printf '<pane ySplit="%s" topLeftCell="A%s" activePane="bottomLeft" state="frozen"/>' \
        "$MAN_FREEZE" "$((MAN_FREEZE + 1))"
      printf '<selection pane="bottomLeft" activeCell="A%s" sqref="A%s"/>' \
        "$((MAN_FREEZE + 1))" "$((MAN_FREEZE + 1))"
    fi
    printf '%s' '</sheetView></sheetViews>'
    printf '%s' '<sheetFormatPr defaultRowHeight="19.5"/>'
    printf '%s' "$MAN_COLS_XML"
    printf '%s' '<sheetData>'
    cat "$MAN_SHEET"
    printf '%s' '</sheetData>'
    [[ -n "$MAN_FILTER" ]] && printf '<autoFilter ref="%s"/>' "$MAN_FILTER"
    ((MAN_NMERGE > 0)) && printf '<mergeCells count="%d">%s</mergeCells>' "$MAN_NMERGE" "$MAN_MERGE"
    printf '%s' '<printOptions horizontalCentered="1"/>'
    printf '%s' '<pageMargins left="0.4" right="0.4" top="0.6" bottom="0.6" header="0.3" footer="0.3"/>'
    printf '%s' '<pageSetup paperSize="9" orientation="landscape" fitToWidth="1" fitToHeight="0"/>'
    printf '%s' '<headerFooter><oddHeader>&amp;L&amp;"Meiryo UI"&amp;9git-diff-helper.sh 利用ガイド&amp;R&amp;"Meiryo UI"&amp;9&amp;A</oddHeader><oddFooter>&amp;C&amp;"Meiryo UI"&amp;9&amp;P / &amp;N</oddFooter></headerFooter>'
    printf '%s' '</worksheet>'
  } >"$MANB/xl/worksheets/sheet${n}.xml"
  rm -f "$MAN_SHEET"
}

#------------------------------------------------------------------------------
# 固定パーツ (Content_Types / rels / workbook / styles)
#   フォントはすべて Meiryo UI。塗り・罫線・配置をスタイル表にまとめて定義する。
#------------------------------------------------------------------------------
write_manual_static() {
  local b="$1" now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')"
  mkdir -p "$b/_rels" "$b/docProps" "$b/xl/_rels" "$b/xl/worksheets"

  {
    printf '%s' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    printf '%s' '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    printf '%s' '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    printf '%s' '<Default Extension="xml" ContentType="application/xml"/>'
    printf '%s' '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
    printf '%s' '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
    local i
    for i in 1 2 3 4 5 6 7 8 9; do
      printf '<Override PartName="/xl/worksheets/sheet%d.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' "$i"
    done
    printf '%s' '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
    printf '%s' '</Types>'
  } >"$b/[Content_Types].xml"

  {
    printf '%s' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    printf '%s' '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    printf '%s' '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
    printf '%s' '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
    printf '%s' '</Relationships>'
  } >"$b/_rels/.rels"

  {
    printf '%s' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    printf '%s' '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
    printf '%s' '<dc:title>git-diff-helper.sh 利用ガイド</dc:title>'
    printf '%s' '<dc:subject>Git 差分ヘルパーの詳しい使い方</dc:subject>'
    printf '%s' '<dc:creator>git-diff-helper.sh</dc:creator>'
    printf '%s' '<cp:lastModifiedBy>git-diff-helper.sh</cp:lastModifiedBy>'
    printf '<dcterms:created xsi:type="dcterms:W3CDTF">%s</dcterms:created>' "$now"
    printf '<dcterms:modified xsi:type="dcterms:W3CDTF">%s</dcterms:modified>' "$now"
    printf '%s' '</cp:coreProperties>'
  } >"$b/docProps/core.xml"

  {
    printf '%s' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    printf '%s' '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
    printf '%s' '<workbookPr/><bookViews><workbookView xWindow="0" yWindow="0" windowWidth="30000" windowHeight="17000" activeTab="0"/></bookViews><sheets>'
    printf '%s' '<sheet name="表紙・概要" sheetId="1" r:id="rId1"/>'
    printf '%s' '<sheet name="セットアップ" sheetId="2" r:id="rId2"/>'
    printf '%s' '<sheet name="モード一覧" sheetId="3" r:id="rId3"/>'
    printf '%s' '<sheet name="オプション一覧" sheetId="4" r:id="rId4"/>'
    printf '%s' '<sheet name="使用例" sheetId="5" r:id="rId5"/>'
    printf '%s' '<sheet name="出力ファイル" sheetId="6" r:id="rId6"/>'
    printf '%s' '<sheet name="レポートの見方" sheetId="7" r:id="rId7"/>'
    printf '%s' '<sheet name="FAQ・トラブル対処" sheetId="8" r:id="rId8"/>'
    printf '%s' '<sheet name="用語集" sheetId="9" r:id="rId9"/>'
    printf '%s' '</sheets></workbook>'
  } >"$b/xl/workbook.xml"

  {
    printf '%s' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    printf '%s' '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    local i
    for i in 1 2 3 4 5 6 7 8 9; do
      printf '<Relationship Id="rId%d" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet%d.xml"/>' "$i" "$i"
    done
    printf '%s' '<Relationship Id="rId10" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
    printf '%s' '</Relationships>'
  } >"$b/xl/_rels/workbook.xml.rels"

  cat >"$b/xl/styles.xml" <<'EOS'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="12"><font><sz val="11"/><color rgb="FF1F1F1F"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font><font><b/><sz val="11"/><color rgb="FF1F1F1F"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font><font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font><font><b/><sz val="20"/><color rgb="FFFFFFFF"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font><font><b/><sz val="13"/><color rgb="FF1F4E79"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font><font><sz val="10.5"/><color rgb="FF0B3B66"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font><font><sz val="9.5"/><color rgb="FF6E6E6E"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font><font><b/><sz val="11"/><color rgb="FF1F4E79"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font><font><b/><sz val="10.5"/><color rgb="FF0B3B66"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font><font><sz val="12"/><color rgb="FFD6E4F0"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font><font><sz val="9.5"/><color rgb="FFB8CCE4"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font><font><b/><sz val="12"/><color rgb="FF1F1F1F"/><name val="Meiryo UI"/><family val="3"/><charset val="128"/></font></fonts><fills count="12"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF1F4E79"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFEAF1F8"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFF7FAFD"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFF3F6F9"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFFFF6DC"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFE8F1FA"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFE7F6EC"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFFCEBEA"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FF2E75B6"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFF0F0F0"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="4"><border><left/><right/><top/><bottom/><diagonal/></border><border><left style="thin"><color rgb="FFD5DDE5"/></left><right style="thin"><color rgb="FFD5DDE5"/></right><top style="thin"><color rgb="FFD5DDE5"/></top><bottom style="thin"><color rgb="FFD5DDE5"/></bottom><diagonal/></border><border><left/><right/><top/><bottom style="medium"><color rgb="FF1F4E79"/></bottom><diagonal/></border><border><left style="thin"><color rgb="FFAFC4D8"/></left><right style="thin"><color rgb="FFAFC4D8"/></right><top style="thin"><color rgb="FFAFC4D8"/></top><bottom style="thin"><color rgb="FFAFC4D8"/></bottom><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="22"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="3" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment horizontal="left" vertical="center"/></xf><xf numFmtId="0" fontId="9" fillId="10" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment horizontal="left" vertical="center"/></xf><xf numFmtId="0" fontId="10" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment horizontal="left" vertical="center"/></xf><xf numFmtId="0" fontId="2" fillId="2" borderId="3" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="4" fillId="0" borderId="2" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="bottom"/></xf><xf numFmtId="0" fontId="11" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment horizontal="left" vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="6" fillId="0" borderId="0" xfId="0" applyFont="1" applyAlignment="1"><alignment horizontal="left" vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="1" fillId="3" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="8" fillId="5" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="5" fillId="5" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="7" fillId="7" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="0" fillId="6" borderId="1" xfId="0" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="0" fillId="8" borderId="1" xfId="0" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="0" fillId="9" borderId="1" xfId="0" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="0" fillId="11" borderId="1" xfId="0" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="1" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="2" fillId="10" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="0" fillId="4" borderId="1" xfId="0" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="left" vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="0" fillId="4" borderId="1" xfId="0" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles><dxfs count="0"/><tableStyles count="0" defaultTableStyle="TableStyleMedium2"/></styleSheet>
EOS
}

#------------------------------------------------------------------------------
# 各シートの中身
#------------------------------------------------------------------------------
man_sheet_cover() {
  man_sheet_begin 1 2 FF1F4E79 \
    '<cols><col min="1" max="1" width="30" customWidth="1"/><col min="2" max="2" width="92" customWidth="1"/></cols>' 0

  man_banner "git-diff-helper.sh  利用ガイド" \
    "Git の差分を 画面 / テキスト / Markdown / Excel に出力するシェルスクリプト" \
    "Version ${VERSION}    |    生成日時: $(date '+%Y-%m-%d %H:%M:%S')    |    対象環境: Red Hat Enterprise Linux 9.6 (bash 5.x / gawk / git 2.x)"

  man_row 8
  man_span 26 lead "はじめての方は「3 ステップで使いはじめる」→「使用例」シートの順にご覧ください。"

  man_section "このツールでできること"
  man_head "特長" "内容"
  local a b
  while IFS='|' read -r a b; do
    [[ -z "$a" ]] && continue
    MAN_Z=$((MAN_ROW % 2)); man_row "" label "$a" plain "$b"
  done <<'EOS'
10 種類のモードに対応|ワークツリー / ステージ / HEAD / 直近 N コミット / 特定コミット / 2 コミット間 / 対話選択 / 複数コミット集約 / ブランチ間 / リモート追跡ブランチ を -m で切り替えられます。
履歴から2コミットを選択|interactive モードでブランチを選択 (既定 main) し、10件ずつの履歴から比較元と比較先を番号で選べます。n / p でページ移動、q で中止します。
複数コミットの変更を集約|multi モードで飛び飛びのコミットを複数選択し、各コミットの親との差分をファイル単位でまとめます。-c の繰り返し指定にも対応します。
4 つの形式に同時出力|画面(色付き)・テキスト(.txt)・Markdown(.md)・Excel(.xlsx) へ一度に出力します。Excel を作れない環境では CSV へ自動的に切り替わります。
旧・新の行番号を併記|差分明細に「変更前の行番号」と「変更後の行番号」を並べて表示するため、レビュー時に該当箇所をすぐ特定できます。
追加ライブラリ不要|xlsx は素の XML と zip だけで生成します。openpyxl などの導入は不要で、閉じた環境でもそのまま使えます。
すべて日本語表示|見出しや状態表示を日本語化しています。Excel は Meiryo UI フォントで読みやすく整形します。
そのまま共有できる|Markdown は GitHub / GitLab / Backlog などの課題やプルリクエストにそのまま貼り付けられます。
EOS
  MAN_Z=0

  man_section "3 ステップで使いはじめる"
  while IFS='|' read -r a b; do
    [[ -z "$a" ]] && continue
    man_row 24 step "$a" code "$b"
  done <<'EOS'
STEP 1  実行権限を付ける|chmod +x git-diff-helper.sh
STEP 2  差分を出力する|./git-diff-helper.sh -m head
STEP 3  出力を開く|./git-diff-report/ に .txt / .md / .xlsx が作成されます
EOS
  man_note "※ 迷ったら -m head です。ステージ済み・未ステージを問わず、未コミットの変更をすべて確認できます。"

  man_section "本ガイドの構成"
  man_head "シート" "内容"
  while IFS='|' read -r a b; do
    [[ -z "$a" ]] && continue
    MAN_Z=$((MAN_ROW % 2)); man_row "" label "$a" plain "$b"
  done <<'EOS'
1. 表紙・概要|できること / 使いはじめ方 / 動作要件
2. セットアップ|配置・実行権限・依存コマンドの導入と動作確認
3. モード一覧|10 種類の比較モードと、その選び方
4. オプション一覧|全オプションの引数・既定値・説明
5. 使用例|目的別のコマンド例 (そのままコピーして使えます)
6. 出力ファイル|出力されるファイルと Excel のシート構成・色分け
7. レポートの見方|差分明細の読み方、記号と色の意味
8. FAQ・トラブル対処|よくある症状と対処、終了コード、制限事項
9. 用語集|ワークツリー・ハンク・三点比較などの用語解説
EOS
  MAN_Z=0

  man_section "動作要件"
  man_head "項目" "内容"
  while IFS='|' read -r a b; do
    [[ -z "$a" ]] && continue
    MAN_Z=$((MAN_ROW % 2)); man_row "" label "$a" plain "$b"
  done <<'EOS'
OS / シェル|Red Hat Enterprise Linux 9.6 / bash 5.x (bash 4.x でも動作します)
必須コマンド|git, bash, awk (gawk 推奨), coreutils (date, mktemp ほか), tr, grep
任意コマンド|zip または python3 … xlsx の生成に使用 / less … --pager 指定時に使用
文字コード|出力は常に UTF-8。CSV は Excel でそのまま開けるよう BOM 付きで出力します。
必要な権限|対象リポジトリの読み取り権限と、出力先ディレクトリ (既定 ./git-diff-report) への書き込み権限
EOS
  MAN_Z=0
  man_note "※ 本ガイドは ./git-diff-helper.sh --manual-only でいつでも再生成できます。"
  man_sheet_end
}

man_sheet_setup() {
  man_sheet_begin 2 4 FF2E75B6 \
    '<cols><col min="1" max="1" width="15" customWidth="1"/><col min="2" max="2" width="22" customWidth="1"/><col min="3" max="3" width="56" customWidth="1"/><col min="4" max="4" width="46" customWidth="1"/></cols>' 0

  man_banner "セットアップ" "配置から動作確認まで、順番どおりに進めれば完了します" \
    "所要時間の目安: 5 分    |    root 権限が必要なのは依存パッケージの導入時のみです"

  local a b c d
  man_section "導入手順"
  man_head "手順" "項目" "コマンド / 操作" "補足"
  while IFS='|' read -r a b c d; do
    [[ -z "$a" ]] && continue
    MAN_Z=$((MAN_ROW % 2)); man_row "" step "$a" label "$b" code "$c" plain "$d"
  done <<'EOS'
STEP 1|ファイルを配置|scp git-diff-helper.sh user@host:/opt/tools/|任意のディレクトリで構いません。
STEP 2|実行権限を付与|chmod +x /opt/tools/git-diff-helper.sh|実行権限が無いと「Permission denied」になります。
STEP 3|依存を確認|rpm -q git gawk coreutils zip|未導入のものがあれば次の表を参照してください。
STEP 4|動作を確認|./git-diff-helper.sh -h|ヘルプが表示されれば準備完了です。
STEP 5|パスを通す (任意)|sudo cp git-diff-helper.sh /usr/local/bin/git-diff-helper|どのディレクトリからでも実行できるようになります。
EOS
  MAN_Z=0

  man_section "依存コマンド"
  man_head "コマンド" "区分" "用途" "RHEL 9 での導入"
  while IFS='|' read -r a b c d; do
    [[ -z "$a" ]] && continue
    MAN_Z=$((MAN_ROW % 2)); man_row "" key "$a" center "$b" plain "$c" code "$d"
  done <<'EOS'
git|必須|差分と履歴の取得|dnf install -y git
bash|必須|スクリプトの実行 (5.x 推奨)|標準搭載
awk (gawk)|必須|差分の解析と整形|dnf install -y gawk
coreutils|必須|date / mktemp / basename など|標準搭載
tr, grep|必須|NUL 区切りの変換と整形|標準搭載
zip|任意 (推奨)|xlsx の圧縮|dnf install -y zip
python3|任意|zip が無い場合の代替 (python3 -m zipfile)|dnf install -y python3
less|任意|--pager 指定時の画面送り|dnf install -y less
EOS
  MAN_Z=0

  man_section "動作確認"
  man_head "確認内容" "コマンド" "期待される結果" "補足"
  while IFS='|' read -r a b c d; do
    [[ -z "$a" ]] && continue
    MAN_Z=$((MAN_ROW % 2)); man_row "" label "$a" code "$b" plain "$c" plain "$d"
  done <<'EOS'
ヘルプ表示|./git-diff-helper.sh --help|書式とオプション一覧が表示される|どこで実行しても構いません。
モード一覧|./git-diff-helper.sh -l|10 モードの一覧が表示される|同上
実際の差分|./git-diff-helper.sh -m head|画面表示のあと出力ファイルの一覧が表示される|git リポジトリの中で実行してください。
利用ガイド|./git-diff-helper.sh --manual-only|本ガイドの xlsx が生成される|git リポジトリの外でも実行できます。
EOS
  MAN_Z=0

  man_section "つまずきやすい点"
  man_tip "zip も python3 も無い環境では、Excel 出力が自動的に CSV (UTF-8 BOM 付き) へ切り替わります。CSV で固定したい場合は -x csv を指定します。"
  man_tip "LANG が C などの非 UTF-8 環境でも動作します。罫線は自動的に ASCII 文字へ切り替わります (--ascii で明示指定も可能)。"
  man_tip "出力先を固定したい場合は -o /var/tmp/diffrep のように指定してください。存在しない場合は自動的に作成します。"
  man_tip "既定では実行のたびに利用ガイド Excel も出力されます。不要な場合は --no-manual を指定してください。"
  man_sheet_end
}

man_sheet_modes() {
  man_sheet_begin 3 6 FF1F7A5C \
    '<cols><col min="1" max="1" width="14" customWidth="1"/><col min="2" max="2" width="18" customWidth="1"/><col min="3" max="3" width="26" customWidth="1"/><col min="4" max="4" width="26" customWidth="1"/><col min="5" max="5" width="30" customWidth="1"/><col min="6" max="6" width="46" customWidth="1"/></cols>' 6

  man_banner "モード一覧" "-m で「何と何を比べるか」を指定します" \
    "別名でも指定できます (例: -m wt は -m worktree と同じ)    |    比較元 = 変更前 / 比較先 = 変更後"

  local a b c d e f
  man_section "10 種類の比較モード"
  man_head "モード" "別名" "比較元 (左)" "比較先 (右)" "実行される git コマンド" "こんなときに使う"
  while IFS='|' read -r a b c d e f; do
    [[ -z "$a" ]] && continue
    MAN_Z=$((MAN_ROW % 2)); man_row "" key "$a" plain "$b" plain "$c" plain "$d" code "$e" plain "$f"
  done <<'EOS'
worktree|wt, unstaged|ステージ (インデックス)|ワークツリー (作業ツリー)|git diff|まだ git add していない変更を確認したいとき
staged|cached, index|HEAD (最新コミット)|ステージ (インデックス)|git diff --cached|git add 済み・未コミットの内容をコミット前に確認したいとき
head|latest|HEAD (最新コミット)|ワークツリー (作業ツリー)|git diff HEAD|未コミットの変更をまとめて確認したいとき (最もよく使います)
prev|last|HEAD~N (N 個前のコミット)|HEAD (最新コミット)|git diff HEAD~N HEAD|直近 N 件のコミットで何が変わったかを見返したいとき (-n で N を指定)
commit|(なし)|指定コミットの親|指定コミット|git diff <親> <指定>|特定の 1 コミットが加えた変更だけを見たいとき (-f で指定)
commits|range|指定コミット (-f)|指定コミット (-t)|git diff <from> <to>|リリース間など、2 点間の変更をまとめたいとき
interactive|select|一覧から選択 (変更前)|一覧から選択 (変更後)|git diff <from> <to>|ブランチ (既定 main) の履歴を10件ずつ見て2点を選びたいとき
multi|multi-select|各コミットの第1親 (初回は空ツリー)|選択した各コミット|git diff <親> <コミット> を選択分実行|飛び飛びのコミットの変更をファイル単位でまとめたいとき。対話選択または -c を繰り返して指定
branches|branch|分岐点 (共通祖先)|比較先ブランチ|git diff <from>...<to>|ブランチのレビュー。分岐後に加わった変更だけを見たいとき
remote|upstream|リモート追跡ブランチ|ローカル HEAD|git diff <upstream> HEAD|push 前にリモートとの差を確認したいとき
EOS
  MAN_Z=0
  man_filter

  man_section "迷ったときの選び方"
  man_tip "「これから git add する内容を確認したい」  →  -m worktree"
  man_tip "「コミットする直前に最終確認したい」  →  -m staged"
  man_tip "「未コミットの変更を全部まとめて見たい」  →  -m head  (迷ったらこれ)"
  man_tip "「さっきのコミットで何を変えたか見返したい」  →  -m prev  (3 件分なら -n 3)"
  man_tip "「履歴から2コミットを選びたい」  →  -m interactive  (ブランチ選択の既定は main、-b で変更)"
  man_tip "「複数コミットの変更・追加をまとめたい」  →  -m multi  (対話なしなら -c <SHA> を繰り返し指定)"
  man_tip "「レビュー用にブランチの差分をまとめたい」  →  -m branches -f main -t <作業ブランチ>"
  man_tip "「push 前にリモートとの差を確認したい」  →  -m remote"

  man_section "補足"
  man_note "interactive はブランチ番号／名前 → 比較元の番号 → 比較先の番号の順に選びます。各入力は Enter で確定し、n / p で次／前の10件、q で中止します。"
  man_note "interactive の番号はページごとに1～10です。比較先は最新ページから選び直します。同じコミットは選べません。選択順に二点比較し、自動で前後を入れ替えません。"
  man_note "interactive はローカル／リモート追跡ブランチを対象にし、チェックアウトや fetch は行いません。-f / -t / --merge-base は併用できません。"
  man_note "multi は番号を空白／カンマで区切って選択・解除します (例: 1 3 / 1,3)。[x] が選択済み、n / p でページ移動、d で1件以上を確定、q で中止します。ページを移動しても選択は保持します。"
  man_note "multi は各コミットの第1親との差分を選択順に集計します。未選択コミット自身の差分は含めませんが、コンテキストにはその時点の内容が表示されます。-U 0 で変更行だけにできます。"
  man_note "multi の初回コミットは空ツリーと比較し、親が取得できない浅い履歴はエラーにします。マージには取り込まれた変更が含まれ、取り込み元も選ぶと重複計上する場合があります。"
  man_note "multi の追加／削除行数は合算で、後で戻した変更も相殺しません。最終状態の差分ではありません。明細のコミットSHA・親SHAを確認し、行番号はそれぞれの親／対象コミットで参照してください。"
  man_note "multi は -f / -t / --merge-base を併用できません。-c と --branch も併用できません。同一コミットを -c で重複指定しても1回だけ集計し、引数順に表示します。作業ファイルやインデックスは変更しません。"
  man_note "三点比較 (A...B) は「A から分岐した後に B 側で加えられた変更」を表示します。branches / remote モードの既定動作で、レビューに適しています。--no-merge-base を付けると先端同士の二点比較になります。"
  man_note "コミットが 1 件も無いリポジトリや、履歴数を超える -n を指定した場合は、自動的に「空ツリー (ファイルが 1 つも無い状態)」との比較へフォールバックします。"
  man_note "-t を省略した場合、commits / branches モードでは比較先が HEAD になります。remote モードでは追跡ブランチを自動判定します。"
  man_sheet_end
}

man_sheet_options() {
  man_sheet_begin 4 6 FFB07D2B \
    '<cols><col min="1" max="1" width="16" customWidth="1"/><col min="2" max="2" width="10" customWidth="1"/><col min="3" max="3" width="22" customWidth="1"/><col min="4" max="4" width="14" customWidth="1"/><col min="5" max="5" width="18" customWidth="1"/><col min="6" max="6" width="62" customWidth="1"/></cols>' 6

  man_banner "オプション一覧" "分類ごとに全オプションをまとめています" \
    "見出し行のフィルタで分類を絞り込めます    |    オプションはモード指定の前後どちらに書いても構いません"

  local a b c d e f
  man_section "全オプション"
  man_head "分類" "短縮形" "オプション" "引数" "既定値" "説明"
  while IFS='|' read -r a b c d e f; do
    [[ -z "$a" ]] && continue
    MAN_Z=$((MAN_ROW % 2)); man_row "" plain "$a" center "$b" key "$c" center "$d" center "$e" plain "$f"
  done <<'EOS'
比較対象|-f|--from|<REF>|(モード依存)|比較元。コミット / ブランチ / タグ / SHA を指定します。commit モードでは対象コミットの指定に使います。
比較対象|-t|--to|<REF>|HEAD|比較先。省略時は HEAD を使用します。remote モードでは追跡先の明示指定に使えます。
比較対象|-b|--branch|<BRANCH>|main|interactive / multi のブランチ選択で Enter を押したときの既定値。ブランチ名 (例 develop / origin/main) を指定します。
比較対象|-c|--commit|<REF>|(対話選択)|multi の対象コミット。繰り返し指定でき、コミットSHAに解決して重複を除きます。省略すると対話で複数選択します。
比較対象|-n|--back|<N>|1|prev モードで N 個前のコミット (HEAD~N) と比較します。1 以上の整数を指定します。
比較対象|(なし)|--merge-base|(なし)|branches/remote で有効|三点比較 (A...B)。分岐後に加えられた変更のみを表示します。
比較対象|(なし)|--no-merge-base|(なし)|(なし)|二点比較 (A B)。2 つの先端の状態をそのまま比較します。
入出力|-r|--repo|<DIR>|. (カレント)|対象リポジトリのパス。cd せずに別のリポジトリを対象にできます。
入出力|-o|--outdir|<DIR>|./git-diff-report|出力先ディレクトリ。存在しない場合は自動的に作成します。
入出力|(なし)|--prefix|<NAME>|git-diff|出力ファイル名の接頭辞。案件名などを指定すると整理しやすくなります。
差分の取り方|-U|--context|<N>|3|差分の前後に表示する文脈行数。0 で変更行のみになります。
差分の取り方|-w|--ignore-space|(なし)|無効|空白だけの差分を無視します。インデント修正時に有効です。
差分の取り方|(なし)|--no-renames|(なし)|検出する|リネーム検出を行いません。改名を「削除 + 追加」として扱います。
差分の取り方|(なし)|--|<パス>...|(なし)|以降をパス指定として扱い、対象のファイル / ディレクトリを限定します。
出力形式|-x|--excel|<FMT>|auto|Excel の形式。auto / xlsx / csv / none から選びます。
出力形式|(なし)|--no-excel|(なし)|出力する|Excel (および利用ガイド) を出力しません。
出力形式|(なし)|--no-text|(なし)|出力する|テキスト (.txt) を出力しません。
出力形式|(なし)|--no-md|(なし)|出力する|Markdown (.md) を出力しません。
出力形式|(なし)|--md-linenos|(なし)|無効|Markdown の差分行に旧 / 新の行番号を併記します。
出力形式|(なし)|--no-screen|(なし)|表示する|画面出力を行いません。バッチ実行時に指定します。
出力形式|(なし)|--no-raw|(なし)|含める|テキスト / Markdown に生の git diff 出力を含めません。
出力形式|(なし)|--manual|(なし)|出力する|利用ガイド Excel (本ファイル) を必ず出力します。
出力形式|(なし)|--no-manual|(なし)|(なし)|利用ガイド Excel を出力しません。
出力形式|(なし)|--manual-only|(なし)|(なし)|利用ガイド Excel だけを生成して終了します。モード指定は不要です。
表示調整|(なし)|--summary-only|(なし)|無効|差分明細を出さず、サマリだけを表示します。全体像の把握に便利です。
表示調整|(なし)|--max-lines|<N>|0 (無制限)|1 ファイルあたりの明細表示行数の上限。画面 / テキスト / Markdown に適用されます。
表示調整|(なし)|--excel-max-rows|<N>|100000|Excel の差分明細シートの最大行数。超過分は末尾に件数を記録します。
表示調整|(なし)|--ascii|(なし)|自動判定|罫線などを ASCII 文字だけで描画します。非 UTF-8 端末向けです。
表示調整|(なし)|--no-color|(なし)|自動判定|画面出力を色無しにします。
表示調整|(なし)|--color|(なし)|自動判定|リダイレクト時でも画面出力を色付きにします。
表示調整|(なし)|--pager|(なし)|無効|画面出力を less -R に流します。長い差分の閲覧に便利です。
情報表示|-l|--list-modes|(なし)|(なし)|モード一覧を表示して終了します。
情報表示|-h|--help|(なし)|(なし)|ヘルプを表示して終了します。
情報表示|-V|--version|(なし)|(なし)|バージョンを表示して終了します。
EOS
  MAN_Z=0
  man_filter

  man_section "指定のしかた"
  man_note "オプションはモード指定の前後どちらに書いても構いません。例: ./git-diff-helper.sh -w -m head も ./git-diff-helper.sh -m head -w も同じ結果になります。"
  man_note "パス指定は必ず -- の後に記述してください。例: ./git-diff-helper.sh -m head -- src/ docs/README.md"
  man_note "モードは -m を省いて先頭に書くこともできます。例: ./git-diff-helper.sh head"
  man_sheet_end
}

man_sheet_examples() {
  man_sheet_begin 5 4 FF7B4EA3 \
    '<cols><col min="1" max="1" width="6" customWidth="1"/><col min="2" max="2" width="36" customWidth="1"/><col min="3" max="3" width="66" customWidth="1"/><col min="4" max="4" width="44" customWidth="1"/></cols>' 6

  man_banner "使用例" "目的から探せるコマンド集。そのままコピーして使えます" \
    "実行前に対象リポジトリへ移動するか、-r <リポジトリのパス> を指定してください"

  local a b c d
  man_section "目的別コマンド"
  man_head "No" "目的" "コマンド" "補足"
  while IFS='|' read -r a b c d; do
    [[ -z "$a" ]] && continue
    MAN_Z=$((MAN_ROW % 2)); man_row "" center "$a" plain "$b" code "$c" plain "$d"
  done <<'EOS'
1|まだ git add していない変更を見る|./git-diff-helper.sh -m worktree|作業中の内容の確認に。
2|git add 済み・未コミットの変更を見る|./git-diff-helper.sh -m staged|コミット直前の最終確認に。
3|未コミットの変更をすべて見る|./git-diff-helper.sh -m head|最もよく使うモードです。
4|直近 1 コミットの変更を見る|./git-diff-helper.sh -m prev|直前の作業内容の振り返りに。
5|直近 3 コミット分の変更を見る|./git-diff-helper.sh -m prev -n 3|-n で遡る件数を指定します。
6|特定コミットが加えた変更を見る|./git-diff-helper.sh -m commit -f a1b2c3d|-f にコミット / タグ / SHA を指定します。
7|2 つのコミット間の変更を見る|./git-diff-helper.sh -m commits -f v1.0.0 -t v1.1.0|リリースノートの作成に。
8|ブランチのレビュー用に差分を出す|./git-diff-helper.sh -m branches -f main -t feature/login|分岐後の変更のみ (三点比較)。
9|ブランチの先端同士を単純比較する|./git-diff-helper.sh -m branches -f main -t feature/login --no-merge-base|両者の現在の状態を比べます。
10|push 前にリモートとの差を見る|./git-diff-helper.sh -m remote|追跡ブランチを自動判定します。
11|比較先のリモートを明示する|./git-diff-helper.sh -m remote -t origin/develop|追跡設定が無い場合はこちら。
12|対象ディレクトリを絞り込む|./git-diff-helper.sh -m head -- src/ docs/README.md|パス指定は -- の後に書きます。
13|別のリポジトリを対象にする|./git-diff-helper.sh -m head -r /srv/git/myapp|cd は不要です。
14|出力先を変える|./git-diff-helper.sh -m head -o /var/tmp/diffrep|存在しない場合は自動作成します。
15|ファイル名の接頭辞を変える|./git-diff-helper.sh -m head --prefix release-1.1|案件ごとに整理できます。
16|Markdown だけを作る|./git-diff-helper.sh -m head --no-excel --no-text --no-screen|課題管理システムへの貼り付け用。
17|Markdown に行番号を併記する|./git-diff-helper.sh -m head --md-linenos|差分行の先頭に旧 / 新の行番号を表示します。
18|空白だけの差分を無視する|./git-diff-helper.sh -m head -w|インデント修正時に有効です。
19|サマリだけを素早く見る|./git-diff-helper.sh -m head --summary-only|大量差分の全体把握に。
20|巨大な差分を扱う|./git-diff-helper.sh -m branches -f main -t big --max-lines 200 --excel-max-rows 50000|表示行数と Excel 行数を制限します。
21|文脈行を増やして読む|./git-diff-helper.sh -m head -U 10|変更前後を 10 行ずつ表示します。
22|バッチ処理でファイルだけ作る|./git-diff-helper.sh -m head --no-screen -o /var/log/diff|cron などでの定期取得に。
23|色付きのまま画面を送る|./git-diff-helper.sh -m head --pager|less -R に流します。
24|利用ガイドだけを作る|./git-diff-helper.sh --manual-only -o ./docs|本ファイルを再生成します。
25|ブランチの履歴から2コミットを選ぶ|./git-diff-helper.sh -m interactive|Enter で main。番号で比較元／比較先を選び、n / p で10件ずつ移動します。
26|別ブランチを既定にして履歴を選ぶ|./git-diff-helper.sh -m interactive -b develop -r /srv/git/myapp|チェックアウト中のブランチを変更せずに比較します。
27|飛び飛びのコミットを複数選択する|./git-diff-helper.sh -m multi|番号を空白／カンマで区切って選択・解除。n / p でページ移動、d で確定します。
28|対象コミットを指定して集約する|./git-diff-helper.sh -m multi -c a1b2c3d -c f9e8d7c -- src/|対話なしで指定した各コミットの変更をファイル単位でまとめます。
EOS
  MAN_Z=0
  man_filter

  man_section "組み合わせのコツ"
  man_tip "定期取得は  --no-screen  と  -o <固定ディレクトリ>  の組み合わせが便利です。終了コード 0 が正常終了です。"
  man_tip "レビュー依頼には Markdown (.md)、報告書には Excel (.xlsx)、記録用にはテキスト (.txt) と使い分けられます。"
  man_tip "巨大な差分では  --summary-only  で全体像をつかんでから、-- でパスを絞って詳細を見ると効率的です。"
  man_sheet_end
}

man_sheet_outputs() {
  man_sheet_begin 6 4 FF0E7C86 \
    '<cols><col min="1" max="1" width="16" customWidth="1"/><col min="2" max="2" width="40" customWidth="1"/><col min="3" max="3" width="62" customWidth="1"/><col min="4" max="4" width="28" customWidth="1"/></cols>' 0

  man_banner "出力ファイル" "1 回の実行で 画面・テキスト・Markdown・Excel がそろいます" \
    "既定の出力先: ./git-diff-report    |    ファイル名: <接頭辞>_<モード>_<YYYYMMDD_HHMMSS>.<拡張子>"

  local a b c d
  man_section "出力されるもの"
  man_head "種別" "ファイル名" "内容" "抑止 / 切替オプション"
  while IFS='|' read -r a b c d; do
    [[ -z "$a" ]] && continue
    MAN_Z=$((MAN_ROW % 2)); man_row "" label "$a" code "$b" plain "$c" plain "$d"
  done <<'EOS'
画面|(ファイルなし)|色分け・行番号付きの差分表示。端末が非対応なら自動的に色無しになります。|--no-screen / --color / --no-color
テキスト|<接頭辞>_<モード>_<日時>.txt|画面と同じ内容 (色なし) に加え、参考として生の git diff を末尾に付けます。|--no-text / --no-raw
Markdown|<接頭辞>_<モード>_<日時>.md|表とコードブロックで構成したレポート。GitHub 等でそのまま読めます。|--no-md / --md-linenos
Excel|<接頭辞>_<モード>_<日時>.xlsx|4 シート構成の差分レポート。枠固定・オートフィルタ設定済みです。|--no-excel / -x csv
CSV|<接頭辞>_<モード>_<日時>_N_*.csv|xlsx を作れない環境での代替。UTF-8 BOM 付きでそのまま Excel で開けます。|-x csv / -x none
利用ガイド|<接頭辞>_使い方ガイド_<日時>.xlsx|本ファイル。9 シート構成・Meiryo UI で整形しています。|--no-manual / --manual-only
EOS
  MAN_Z=0

  man_section "差分レポート Excel のシート構成"
  man_head "シート" "主な列" "用途" "備考"
  while IFS='|' read -r a b c d; do
    [[ -z "$a" ]] && continue
    MAN_Z=$((MAN_ROW % 2)); man_row "" label "$a" plain "$b" plain "$c" plain "$d"
  done <<'EOS'
サマリ|項目 / 内容|実行条件と集計値。まずここを確認します。|実行コマンドも記録されるため再現できます。
ファイル一覧|No / 状態 / 状態コード / 追加行 / 削除行 / 変更行合計 / 種別 / ファイル(新) / ファイル(旧)|変更されたファイルの一覧。|オートフィルタで状態や種別を絞り込めます。
差分明細|No / ファイルNo / ファイル / ハンク / 旧行番号 / 新行番号 / 区分 / 記号 / 内容|1 行 1 レコードの差分本体。|区分やファイル名で絞り込めます。既定 100,000 行まで。
コミット履歴|No / コミット / 日時 / 作成者 / 件名|対象範囲のコミット一覧。multi は選択コミットのみ。|prev / commit / commits / interactive / multi / branches / remote モードで出力されます。
EOS
  MAN_Z=0

  man_section "色分けの凡例 (差分レポート Excel)"
  man_head "表示例" "意味" "背景色" "備考"
  man_row "" good "+  追加された行" plain "追加行" plain "緑 (E6FFEC)" plain "変更後にだけ存在する行です。"
  man_row "" bad  "-  削除された行" plain "削除行" plain "赤 (FFEBE9)" plain "変更前にだけ存在する行です。"
  man_row "" accent "@@  ハンク見出し" plain "変更箇所の位置情報" plain "青 (DDEBF7)" plain "旧 / 新の開始行と行数を示します。"
  man_row "" gray "old mode 100644" plain "属性情報・バイナリ" plain "灰 (F2F2F2)" plain "モード変更・改名・バイナリの情報行です。"

  man_section "補足"
  man_note "差分レポート Excel は見出し行のウィンドウ枠固定とオートフィルタを設定済みです。内容列は等幅フォント (Consolas) のため、ソースコードのインデントが崩れません。"
  man_note "本利用ガイドは全シートを Meiryo UI で作成しています。印刷は A4 横・横方向に 1 ページ幅で収まるよう設定済みです。"
  man_note "zip も python3 も見つからない場合は、自動的に CSV 出力へフォールバックします (この場合、利用ガイド Excel は生成されません)。"
  man_sheet_end
}

man_sheet_reading() {
  man_sheet_begin 7 4 FFC0504D \
    '<cols><col min="1" max="1" width="13" customWidth="1"/><col min="2" max="2" width="13" customWidth="1"/><col min="3" max="3" width="9" customWidth="1"/><col min="4" max="4" width="84" customWidth="1"/></cols>' 0

  man_banner "レポートの見方" "差分明細は「旧行番号 / 新行番号 / 記号 / 内容」で読み解きます" \
    "画面・テキスト・Markdown・Excel のいずれも同じ考え方で読めます"

  local a b
  man_section "画面 / テキストの構成"
  man_head "セクション" "" "" "内容"
  man_merge_cur 1 3
  while IFS='|' read -r a b; do
    [[ -z "$a" ]] && continue
    MAN_Z=$((MAN_ROW % 2))
    man_row "" label "$a" label "" label "" plain "$b"
    man_merge_cur 1 3
  done <<'EOS'
[ 実行条件 ]|実行日時・リポジトリ・ブランチ・HEAD・モード・比較内容・実行コマンドなど、再現に必要な情報です。
[ 差分サマリ ]|変更ファイル数 / 追加行数 / 削除行数 / 差引行数 / 状態の内訳。全体の規模をつかみます。
[ ファイル別サマリ ]|No・状態・追加・削除・変化量バー・ファイル名。どのファイルが大きく変わったか一目で分かります。
[ 対象コミット一覧 ]|prev / commit / commits / interactive / multi / branches / remote モードでのみ表示されます。multi は選択コミットのみを選択順に表示します。
[ 差分明細 ]|ファイルごとに、ハンク見出しと変更行を「旧行番号・新行番号・記号・内容」の形で表示します。
EOS
  MAN_Z=0

  man_section "差分明細の読み方 (見本)"
  man_head "旧行番号" "新行番号" "記号" "内容"
  man_row "" accent "" accent "" accent "@@" accent "旧: 8 行目から 3 行  →  新: 8 行目から 4 行     int main(int argc, char **argv) {"
  man_row "" center 8 center 8 center "" code "        }"
  man_row "" center 9 center 9 center "" code "        return EXIT_SUCCESS;"
  man_row "" center "" center 10 center "+" good "        printf(\"追加された行\\n\");"
  man_row "" center 10 center "" center "-" bad "        printf(\"削除された行\\n\");"
  man_note "上の例は「変更前の 8 行目から 3 行分」が「変更後の 8 行目から 4 行分」に置き換わったことを表します。旧行番号だけがある行は削除、新行番号だけがある行は追加、両方ある行は変更なし (前後の文脈) です。"

  man_section "記号と色の対応"
  man_head "記号" "区分" "色" "意味"
  man_row "" center "+" plain "追加行" good "緑" plain "変更後にだけ存在する行です。"
  man_row "" center "-" plain "削除行" bad "赤" plain "変更前にだけ存在する行です。"
  man_row "" center "(空白)" plain "変更なし" plain "白" plain "前後の文脈として表示される行です。-U で表示行数を変更できます。"
  man_row "" center "@@" plain "ハンク見出し" accent "青" plain "変更箇所のまとまりの位置 (旧 / 新の開始行と行数) を示します。"
  man_row "" center "(なし)" plain "属性情報" gray "灰" plain "モード変更・改名・バイナリなどの情報行です。"

  man_section "状態コードの意味"
  man_head "コード" "状態" "" "説明"
  man_merge_cur 2 3
  while IFS='|' read -r a b; do
    [[ -z "$a" ]] && continue
    MAN_Z=$((MAN_ROW % 2))
    man_row "" center "${a%%:*}" plain "${a##*:}" plain "" plain "$b"
    man_merge_cur 2 3
  done <<'EOS'
M:変更|既存ファイルの内容が変更されました。
A:追加|新しく追加されたファイルです。
D:削除|削除されたファイルです。
R:改名|ファイル名が変更されました。R100 のように類似度が付きます (100 は内容が完全一致)。
C:複製|既存ファイルをコピーして作られたファイルです。
T:型変更|通常ファイルとシンボリックリンクの間などで、種別が変わりました。
U:競合|マージが未解決の状態です。競合を解消してから再実行してください。
EOS
  MAN_Z=0

  man_section "Markdown レポートの見方"
  man_note "Markdown は「表 + diff コードブロック」で構成されます。GitHub / GitLab / Backlog などに貼り付けると、追加行が緑・削除行が赤で表示されます。"
  man_note "各ハンクの見出しに旧 / 新の開始行と行数を記載しています。差分行そのものに行番号を併記したい場合は --md-linenos を指定してください。"
  man_note "差分本文にコードフェンス (バッククォート 3 個) を含むファイルでもレイアウトが崩れないよう、フェンスにはバッククォート 4 個を使用しています。"
  man_note "生の git diff は末尾の折りたたみ (details) に格納しています。不要な場合は --no-raw を指定してください。"
  man_sheet_end
}

man_sheet_faq() {
  man_sheet_begin 8 3 FF5B6B7B \
    '<cols><col min="1" max="1" width="42" customWidth="1"/><col min="2" max="2" width="40" customWidth="1"/><col min="3" max="3" width="66" customWidth="1"/></cols>' 6

  man_banner "FAQ・トラブル対処" "よくある症状と、その場で試せる対処をまとめました" \
    "解決しない場合は ./git-diff-helper.sh -h でヘルプを確認してください"

  local a b c
  man_section "よくある症状と対処"
  man_head "症状・質問" "原因" "対処"
  while IFS='|' read -r a b c; do
    [[ -z "$a" ]] && continue
    MAN_Z=$((MAN_ROW % 2)); man_row "" label "$a" plain "$b" plain "$c"
  done <<'EOS'
「git リポジトリではありません」と表示される|カレントディレクトリが git の管理下にない|リポジトリ内で実行するか、-r /path/to/repo を指定してください。
「リモート追跡ブランチが設定されていません」と表示される|upstream が未設定|git branch --set-upstream-to=origin/main を実行するか、-t origin/main のように比較先を明示してください。
「コミットが 1 件もありません」と表示される|初回コミット前のリポジトリ|worktree / staged / head モードは空ツリーとの比較へ自動フォールバックします。prev / remote はコミットが必要です。
Excel が出力されず CSV になる|zip も python3 も見つからない|sudo dnf install -y zip を実行してください。CSV のままでよい場合は -x csv を明示できます。
罫線が □ や ? で表示される|端末やロケールが UTF-8 でない|--ascii を指定すると ASCII 文字だけで描画します。
画面が色付きにならない|リダイレクト時は自動的に色を抑止する仕様|--color を指定すると必ず色付きで出力します。
Permission denied で起動しない|実行権限が無い|chmod +x git-diff-helper.sh を実行してください。
出力先ディレクトリを作成できない|書き込み権限が無い|-o で書き込み可能なディレクトリを指定してください。
差分が大量で開くのに時間がかかる|明細行が多い|--max-lines で表示行数を制限、--summary-only で概要のみ出力、-- でパスを絞り込みます。
Excel の差分明細が途中で切れている|既定の上限 100,000 行を超えた|--excel-max-rows で上限を変更してください。末尾に省略した行数が記録されます。
インデントを直しただけで差分が大量に出る|空白の変更が差分として検出される|-w (--ignore-space) を指定すると空白のみの差分を無視します。
ファイル名を変えたのに削除 + 追加になる|類似度が低くリネームと判定されなかった|内容が大きく変わった場合の仕様です。--no-renames で常に削除 + 追加として扱えます。
日本語ファイル名が数字の羅列になる|git の quotepath 設定|本スクリプトは core.quotepath=false を指定済みです。表示側の文字コード設定をご確認ください。
利用ガイドが毎回出力されて邪魔|既定で出力する設定のため|--no-manual を指定してください。必要なときだけ --manual-only で生成できます。
Markdown が不要|—|--no-md を指定してください。テキストのみなら --no-md --no-excel の併用が便利です。
cron から実行したい|—|--no-screen を付け、-o で出力先を固定してください。終了コード 0 が正常終了です。
interactive で main が見つからない|対象リポジトリに main が無い|一覧から別の番号／名前を入力するか、-b develop などで既定値を変更してください。タグや任意の SHA は選択対象外です。
interactive で選択できない／入力が終了する|コミット不足、同一コミットの選択、標準入力の EOF|2件以上の履歴から異なる2コミットを選びます。無人実行には -m commits -f <元> -t <先> を使用してください。
multi の行数が2点比較と異なる|各コミットの追加／削除行数を合算している|後で戻した変更も相殺しません。明細はコミットSHA・親SHAで区切って表示します。最終状態の比較には commits を使います。
multi で確定できない／親コミットが取得できない|未選択、標準入力の EOF、浅い履歴|番号で1件以上を選んで d で確定します。無人実行は -c を繰り返し指定してください。親が無い場合は不足する履歴を取得して再実行します。
改行コードが CRLF のファイルがある|—|行末の CR は除去して表示します。そのままご利用いただけます。
EOS
  MAN_Z=0
  man_filter

  man_section "終了コード"
  man_head "コード" "意味" "補足"
  man_row "" center 0 plain "正常終了" plain "差分の有無にかかわらず 0 を返します。interactive / multi で q により中止した場合も 0 です (レポートは出力しません)。"
  man_row "" center 1 plain "エラー終了" plain "引数エラー / リポジトリ不正 / 参照の解決失敗 / 出力失敗など。標準エラー出力にメッセージを表示します。"

  man_section "制限事項"
  man_note "パス名に改行を含むファイルは正しく扱えません (-z 出力を行単位で解析しているため)。通常の運用では発生しません。"
  man_note "差分明細シートは既定で 100,000 行を上限としています (Excel の実用上の制約)。--excel-max-rows で変更できます。"
  man_note "バイナリファイルは変更の有無のみを記録し、内容の差分は表示しません。"
  man_note "multi は変更後のパス単位 (削除は変更前) で集約し、改名前後を追跡しません。状態が混在する場合は変更 (M)、状態コード欄は A/M などの内訳です。--max-lines は集約後の1ファイル全体に適用します。"
  man_note "画面の罫線は UTF-8 ロケールを自動検出して選択します。全角文字の桁揃えのため、非 UTF-8 環境では awk のみ UTF-8 ロケールで起動します (出力は常に UTF-8)。"
  man_sheet_end
}

man_sheet_glossary() {
  man_sheet_begin 9 4 FF7F6000 \
    '<cols><col min="1" max="1" width="20" customWidth="1"/><col min="2" max="2" width="24" customWidth="1"/><col min="3" max="3" width="64" customWidth="1"/><col min="4" max="4" width="26" customWidth="1"/></cols>' 6

  man_banner "用語集" "レポートやヘルプに出てくる用語の意味" \
    "git に不慣れな方は、まず「ワークツリー」「ステージ」「HEAD」の 3 つを押さえてください"

  local a b c d
  man_section "用語一覧"
  man_head "用語" "英語表記" "意味" "関連するモード / オプション"
  while IFS='|' read -r a b c d; do
    [[ -z "$a" ]] && continue
    MAN_Z=$((MAN_ROW % 2)); man_row "" label "$a" plain "$b" plain "$c" key "$d"
  done <<'EOS'
ワークツリー|working tree|いま実際に編集しているファイルそのもの。エディタで開いている状態です。|worktree / head
ステージ|index / staging area|git add した内容が置かれる、コミット前の待機場所です。|staged
HEAD|HEAD|現在チェックアウトしているブランチの最新コミットを指す参照です。|head / prev
コミット|commit|変更を確定して履歴に記録したもの。40 桁の SHA-1 で識別されます。|commit / commits
ハンク|hunk|差分のかたまり。@@ で始まる見出しと、それに続く変更行の集合です。|-U / --context
コンテキスト行|context line|変更行の前後に表示される、変更されていない行です。|-U / --context
三点比較|three-dot diff|A...B の形式。A から分岐した後に B 側で加わった変更のみを表示します。|--merge-base
二点比較|two-dot diff|A B の形式。2 つの先端の状態をそのまま比較します。|--no-merge-base
共通祖先|merge base|2 つのブランチが分岐した地点のコミットです。|branches / remote
リモート追跡ブランチ|remote-tracking branch|origin/main のように、リモートの状態を記録したローカルの参照です。|remote
upstream|upstream branch|現在のブランチが既定で push / pull する相手先のブランチです。|remote
空ツリー|empty tree|ファイルが 1 つも無い状態を表す特別なオブジェクト。初回コミット前の比較に使います。|staged / head / prev
リネーム検出|rename detection|ファイル名の変更を「削除 + 追加」ではなく「改名」として認識する機能です。|--no-renames
状態コード|status code|M(変更) A(追加) D(削除) R(改名) C(複製) T(型変更) U(競合) の 1 文字です。|ファイル一覧シート
numstat|numstat|ファイルごとの追加行数・削除行数を数値で示す git の出力形式です。|(内部処理)
パス指定|pathspec|対象を絞り込むためのファイル / ディレクトリ指定。-- の後に記述します。|-- <パス>
デタッチ HEAD|detached HEAD|ブランチではなく特定のコミットを直接チェックアウトしている状態です。|(全モード)
EOS
  MAN_Z=0
  man_filter
  man_note "※ 用語をシート内で探す場合は Ctrl + F、絞り込む場合は見出し行のフィルタをご利用ください。"
  man_sheet_end
}

#------------------------------------------------------------------------------
# 利用ガイド Excel の生成本体
#------------------------------------------------------------------------------
make_manual_xlsx() {
  local outfile="$1"
  MANB="$TMPD/manual"
  rm -rf "$MANB"
  write_manual_static "$MANB" || { err "利用ガイドの雛形を作成できませんでした。"; return 1; }

  man_sheet_cover
  man_sheet_setup
  man_sheet_modes
  man_sheet_options
  man_sheet_examples
  man_sheet_outputs
  man_sheet_reading
  man_sheet_faq
  man_sheet_glossary

  zip_package "$MANB" "$outfile" '[Content_Types].xml' _rels docProps xl || return 1
  [[ -s "$outfile" ]] || { err "利用ガイド Excel が生成されませんでした。"; return 1; }
  return 0
}

#==============================================================================
# メイン
#==============================================================================
# 出力先ディレクトリを確定する (未指定なら ./git-diff-report)
prepare_outdir() {
  [[ -n "$OUTDIR" ]] || OUTDIR="./git-diff-report"
  mkdir -p "$OUTDIR" || die "出力先ディレクトリを作成できません: $OUTDIR"
  OUTDIR="$(cd -- "$OUTDIR" && pwd)"
}

# --manual-only: 利用ガイド Excel だけを生成する (git リポジトリ外でも実行可能)
run_manual_only() {
  local ts out
  [[ -n "$(find_zipper)" ]] || die "利用ガイド Excel の生成には zip または python3 が必要です。
  例) sudo dnf install -y zip"
  TMPD="$(mktemp -d "${TMPDIR:-/tmp}/git-diff-helper.XXXXXX")" || die "作業ディレクトリを作成できません。"
  trap 'rm -rf "$TMPD"' EXIT INT TERM
  prepare_outdir
  ts="$(date '+%Y%m%d_%H%M%S')"
  out="${OUTDIR}/${PREFIX}_使い方ガイド_${ts}.xlsx"
  make_manual_xlsx "$out" || die "利用ガイド Excel の生成に失敗しました。"
  local G="" N="" Y=""
  if [[ "$USE_COLOR" == "yes" ]]; then G=$'\033[32m'; Y=$'\033[33m'; N=$'\033[0m'; fi
  printf '\n %s[ 出力ファイル ]%s\n' "$Y" "$N"
  printf '   %s利用ガイド%s : %s\n\n' "$G" "$N" "$out"
}

main() {
  parse_args "$@"
  setup_style
  if ((MANUAL_ONLY)); then
    run_manual_only
    return 0
  fi
  if [[ -z "$MODE" ]]; then
    usage
    echo
    die "モードが指定されていません。 -m <モード> を指定してください。"
  fi
  check_prereq
  detect_awk_locale
  resolve_mode
  build_diff_opts

  CUR_BRANCH="$("${GIT[@]}" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [[ -z "$CUR_BRANCH" || "$CUR_BRANCH" == "HEAD" ]] && CUR_BRANCH="${CUR_BRANCH:-(不明)} (detached HEAD の可能性)"
  if has_head; then
    HEAD_INFO="$("${GIT[@]}" log -1 --date=format:'%Y-%m-%d %H:%M:%S' --pretty=format:'%h  %ad  %an  %s' 2>/dev/null)"
  else
    HEAD_INFO="(コミットなし)"
  fi

  US=$'\037'
  ASCII_FLAG=0; [[ "$ASCII" == "yes" ]] && ASCII_FLAG=1
  TERM_WIDTH="${COLUMNS:-0}"
  if [[ "$TERM_WIDTH" -le 0 ]] && command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
    TERM_WIDTH="$(tput cols 2>/dev/null || echo 0)"
  fi
  [[ "$TERM_WIDTH" =~ ^[0-9]+$ ]] || TERM_WIDTH=0
  ((TERM_WIDTH >= 40)) || TERM_WIDTH=88
  ((TERM_WIDTH > 200)) && TERM_WIDTH=200

  TMPD="$(mktemp -d "${TMPDIR:-/tmp}/git-diff-helper.XXXXXX")" || die "作業ディレクトリを作成できません。"
  trap 'rm -rf "$TMPD"' EXIT INT TERM

  write_awk_programs
  collect_data

  # ---- 出力先の決定 ----
  local ts stamp outbase
  ts="$(date '+%Y%m%d_%H%M%S')"
  # 利用ガイドは Excel 出力の一部として扱う (--manual 明示時は常に出力)
  if ((MANUAL_FORCED == 0)) && { ((DO_EXCEL == 0)) || [[ "$EXCEL_FMT" == "none" ]]; }; then
    DO_MANUAL=0
  fi
  if ((DO_TEXT || DO_MD || DO_EXCEL || DO_MANUAL)); then
    prepare_outdir
  fi
  stamp="${PREFIX}_${MODE}_${ts}"
  outbase="${OUTDIR:-.}/${stamp}"

  # ---- 画面出力 ----
  if ((DO_SCREEN)); then
    local ccolor=0; [[ "$USE_COLOR" == "yes" ]] && ccolor=1
    if ((USE_PAGER)) && command -v less >/dev/null 2>&1; then
      render "$ccolor" | less -R
    else
      render "$ccolor"
    fi
  fi

  OUT_TXT=""; OUT_MD=""; OUT_XLSX=""; OUT_CSV=""; OUT_MANUAL=""

  # ---- テキスト出力 ----
  if ((DO_TEXT)); then
    OUT_TXT="${outbase}.txt"
    {
      render 0
      if ((INCLUDE_RAW)); then
        echo
        echo "================================================================================"
        echo " 【参考】生の git diff 出力"
        echo " コマンド: $DIFF_CMD_DISPLAY"
        echo "================================================================================"
        if [[ -s "$TMPD/patch.txt" ]]; then cat "$TMPD/patch.txt"; else echo "(差分なし)"; fi
      fi
    } > "$OUT_TXT" || die "テキストファイルの出力に失敗しました: $OUT_TXT"
  fi

  # ---- Markdown 出力 ----
  if ((DO_MD)); then
    OUT_MD="${outbase}.md"
    {
      render_md
      if ((INCLUDE_RAW)); then
        echo "## 付録. 生の \`git diff\` 出力"
        echo
        echo "実行コマンド: \`${DIFF_CMD_DISPLAY}\`"
        echo
        echo "<details>"
        echo "<summary>クリックして展開</summary>"
        echo
        echo '````diff'
        if [[ -s "$TMPD/patch.txt" ]]; then cat "$TMPD/patch.txt"; else echo "(差分なし)"; fi
        echo '````'
        echo
        echo "</details>"
        echo
      fi
      echo "---"
      echo
      echo "<sub>generated by \`${SCRIPT_NAME}\` ${VERSION} — $(date '+%Y-%m-%d %H:%M:%S')</sub>"
    } > "$OUT_MD" || die "Markdown ファイルの出力に失敗しました: $OUT_MD"
  fi

  # ---- Excel 出力 ----
  if ((DO_EXCEL)) && [[ "$EXCEL_FMT" != "none" ]]; then
    local fmt="$EXCEL_FMT"
    if [[ "$fmt" == "auto" ]]; then
      if [[ -n "$(find_zipper)" ]]; then fmt="xlsx"; else
        warn "zip / python3 が見つからないため、Excel 出力を CSV 形式に切り替えます。"
        fmt="csv"
      fi
    fi
    case "$fmt" in
      xlsx)
        if [[ -z "$(find_zipper)" ]]; then
          err "xlsx 出力には zip または python3 が必要です。 -x csv をご利用ください。"
        else
          OUT_XLSX="${outbase}.xlsx"
          if make_xlsx "$OUT_XLSX"; then :; else OUT_XLSX=""; fi
        fi
        ;;
      csv)
        make_csv "$outbase" && OUT_CSV="${outbase}_*.csv"
        ;;
      *)
        err "不明な Excel 形式: $fmt  (xlsx | csv | none)"
        ;;
    esac
  fi

  # ---- 利用ガイド Excel の出力 ----
  if ((DO_MANUAL)); then
    if [[ -z "$(find_zipper)" ]]; then
      warn "zip / python3 が見つからないため、利用ガイド Excel は出力しません。"
    else
      OUT_MANUAL="${OUTDIR:-.}/${PREFIX}_使い方ガイド_${ts}.xlsx"
      make_manual_xlsx "$OUT_MANUAL" || OUT_MANUAL=""
    fi
  fi

  # ---- 出力ファイル案内 ----
  if [[ -n "$OUT_TXT$OUT_MD$OUT_XLSX$OUT_CSV$OUT_MANUAL" ]]; then
    local G="" N="" Y=""
    if [[ "$USE_COLOR" == "yes" ]]; then G=$'\033[32m'; Y=$'\033[33m'; N=$'\033[0m'; fi
    printf '\n %s[ 出力ファイル ]%s\n' "$Y" "$N"
    [[ -n "$OUT_TXT"  ]] && printf '   %sテキスト  %s : %s\n' "$G" "$N" "$OUT_TXT"
    [[ -n "$OUT_MD"   ]] && printf '   %sMarkdown  %s : %s\n' "$G" "$N" "$OUT_MD"
    [[ -n "$OUT_XLSX" ]] && printf '   %sExcel     %s : %s\n' "$G" "$N" "$OUT_XLSX"
    if [[ -n "$OUT_CSV" ]]; then
      local f
      for f in "${outbase}"_*.csv; do [[ -e "$f" ]] && printf '   %sCSV       %s : %s\n' "$G" "$N" "$f"; done
    fi
    [[ -n "$OUT_MANUAL" ]] && printf '   %s利用ガイド%s : %s\n' "$G" "$N" "$OUT_MANUAL"
    echo
  fi

  return 0
}

main "$@"
