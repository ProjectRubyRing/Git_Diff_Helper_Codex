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