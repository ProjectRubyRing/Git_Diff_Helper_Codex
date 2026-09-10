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