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