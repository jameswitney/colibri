#!/bin/bash
# st-parse.sh — STAGE 4 acceptance parse for the selftune-defaults bench.
# Reads /tmp/selftune/st-out/audit2-<arm>-rN.{log,mempeak} (n=3 legs an arm,
# legs GREEN per legs/*.status) and prints:
#   1. the per-leg table (rc, ttft, decode, wall, vram0, mem peak, gen md5)
#   2. the per-arm medians/ranges (decode = 63/(wall-ttft), the harness
#      convention, cross-checked against each log's own TTFT line)
# decode is recomputed here from the log's own ttft/wall pair, not trusted
# from summary.txt, so a parse bug cannot reach RESULTS.md.
set -u
OUT=/tmp/selftune/st-out
ARMS="legacy defaults oneline"

legrow(){ # tag (no audit2- prefix)
  local L="$OUT/audit2-$1.log" rc ttft dec wall v0 mp md5
  rc=$(grep -o "^rc=[0-9]*" "$L" 2>/dev/null | tail -1 | cut -d= -f2); rc=${rc:-NA}
  read -r ttft wall <<<"$(awk '
    /time_to_first_token=/ { split($0,a,"time_to_first_token="); split(a[2],b," "); ttft=b[1] }
    /TUNE decode:/         { split($0,c,"TUNE decode:"); split(c[2],d," "); sec=d[4] }
    END { if (sec=="" || ttft=="") print "NA NA"; else printf "%.3f %.3f", ttft, sec }' "$L" 2>/dev/null)"
  if [ "$ttft" != NA ]; then dec=$(awk -v t="$ttft" -v w="$wall" 'BEGIN{printf "%.4f", 63/(w-t)}'); else dec=NA; fi
  v0=$(grep -o "vram0=[0-9]*" "$L" 2>/dev/null | tail -1 | cut -d= -f2)
  mp=$(sed -n 's/^mem peak=\([0-9.]*\)GiB.*/\1/p' "$OUT/audit2-$1.mempeak" 2>/dev/null)
  md5=$(grep -m1 -o "generated_text=.*" "$L" 2>/dev/null | head -c 3000000 | md5sum | cut -d' ' -f1)
  printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n" "$1" "$rc" "${ttft:-NA}" "${dec}" "${wall:-NA}" \
    "$([ -n "$v0" ] && echo $((v0/1048576)) || echo NA)" "${mp:-NA}" "${md5:-NA}"
}

echo "### per-leg"
echo "| leg | rc | ttft s | decode tok/s | wall s | vram0 MiB | mem peak GiB | gen md5 |"
echo "|---|---|---|---|---|---|---|---|"
for a in $ARMS; do for r in 1 2 3; do [ -f "$OUT/legs/audit2-$a-r$r.status" ] && legrow "$a-r$r"; done; done

echo
echo "### per-arm medians (n, decode med [range], ttft med [range])"
for a in $ARMS; do
  for r in 1 2 3; do
    s=$OUT/legs/audit2-$a-r$r.status
    [ -f "$s" ] || continue
    # GREEN direct, GREEN via r2 (log then in audit2-<tag>-r2.log), FAILED -> skip with note
    if grep -q "^GREEN " "$s"; then L=$OUT/audit2-$a-r$r.log
    elif grep -q "^GREEN via r2" "$s"; then L=$OUT/audit2-$a-r$r-r2.log
    else echo "# $a-r$r NOT GREEN: $(head -1 "$s")"; continue; fi
    awk -v tag="$a" '
      /time_to_first_token=/ { split($0,a,"time_to_first_token="); split(a[2],b," "); ttft=b[1] }
      /TUNE decode:/         { split($0,c,"TUNE decode:"); split(c[2],d," "); sec=d[4] }
      END { printf "%s %.3f %.6f %.3f\n", tag, ttft, 63/(sec-ttft), sec }' "$L"
  done
done | awk '
  { arm=$1; n[arm]++; tt[arm,n[arm]]=$2; dd[arm,n[arm]]=$3; if(!(arm in seen)){order[++o]=arm; seen[arm]=1} }
  END {
    printf "| arm | n | decode med | decode range | ttft med | ttft range |\n|---|---|---|---|---|---|\n"
    for (i=1;i<=o;i++){
      a=order[i]; m=n[a]
      # median of the sorted n values
      for (x=1;x<=m;x++){ for (y=x+1;y<=m;y++){ if (dd[a,y]<dd[a,x]){t=dd[a,x];dd[a,x]=dd[a,y];dd[a,y]=t}
                                                   if (tt[a,y]<tt[a,x]){t=tt[a,x];tt[a,x]=tt[a,y];tt[a,y]=t} } }
      dmed = (m%2)? dd[a,(m+1)/2] : (dd[a,m/2]+dd[a,m/2+1])/2
      tmed = (m%2)? tt[a,(m+1)/2] : (tt[a,m/2]+tt[a,m/2+1])/2
      printf "| %s | %d | %.4f | %.4f-%.4f | %.1f | %.1f-%.1f |\n", a, m, dmed, dd[a,1], dd[a,m], tmed, tt[a,1], tt[a,m]
      printf "MED %s decode=%.4f ttft=%.1f\n", a, dmed, tmed
    }
  }'
