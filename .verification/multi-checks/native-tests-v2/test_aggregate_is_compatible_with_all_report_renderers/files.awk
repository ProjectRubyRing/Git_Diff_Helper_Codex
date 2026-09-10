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