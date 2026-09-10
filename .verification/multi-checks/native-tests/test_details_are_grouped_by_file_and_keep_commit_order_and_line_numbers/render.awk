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