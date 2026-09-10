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