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