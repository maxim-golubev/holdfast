#!/bin/zsh
# The 90-minute simulation: compiles the pipeline sources Tools/test.sh compiles with Tests/Soak/*.swift into
# build/soak/soak and drives the real MovieWriter, RecordingMonitor and RecordingMixer through a simulated meeting
# with synthetic buffers on a simulated clock. Nothing is launched, captured or played. Then it kills a second run at
# 45 minutes without finishing its writer and runs the launch recovery on what it left. Reports go to
# build/soak/record.txt, kill.txt and recover.txt; exits non-zero when a check fails. The recordings (about 750 MB)
# are removed at the end unless -k is given. Takes about three minutes; uses ffprobe for a second opinion when present.
# Usage: Tools/soak.sh [-k] [record|kill]
cd "$(dirname "$0")/.."
keep=0
if [[ $1 == -k ]]; then keep=1; shift; fi
only=$1
# The pipeline sources of Tools/test.sh, without its tests
sources=(${(f)"$(sed -n '/^sources=(/,/^)/p' Tools/test.sh | grep '^ *Holdfast/' | sed 's/^ *//')"} Tests/Soak/*.swift)
out=build/soak
mkdir -p $out
binary=$out/soak
if [[ ! -x $binary || "$(<$binary.sources)" != "$sources" || -n $(find $sources Tools/soak.sh -newer $binary) ]] 2>/dev/null; then
  rm -f $binary $binary.sources
  swiftc -O -suppress-warnings -swift-version 5 -target arm64-apple-macosx15.0 -o $binary $sources || { echo "SOAK FAILED TO BUILD"; exit 1 }
  print -r -- "$sources" > $binary.sources
fi
rm -rf $out/record $out/kill
result=0

# Runs the binary under /usr/bin/time -l, whose peak memory and wall time are appended to the report
run() {
  local name=$1; shift
  /usr/bin/time -l $binary "$@" > $out/$name.txt 2> $out/$name.time
  local rc=$?
  { echo; echo "/usr/bin/time -l:"; grep -E 'real|maximum resident|peak memory' $out/$name.time | sed 's/^ */  /' } >> $out/$name.txt
  return $rc
}

if [[ -z $only || $only == record ]]; then
  echo "recording 90 simulated minutes ..."
  run record record $out/record || result=1
  grep -E '^SOAK' $out/record.txt
fi
if [[ -z $only || $only == kill ]]; then
  echo "recording until the kill at 45 minutes ..."
  run kill kill $out/kill
  # The run kills itself: SIGKILL is the expected end, which time reports as an abnormal termination
  if ! grep -q 'terminated abnormally' $out/kill.time || ! grep -q 'killing the process' $out/kill.txt; then
    echo "the killed run was not killed as planned"; result=1
  fi
  echo "recovering what it left ..."
  run recover recover $out/kill || result=1
  grep -E '^SOAK' $out/recover.txt
fi
(( keep )) || rm -rf $out/record $out/kill
echo "reports: $out/record.txt $out/kill.txt $out/recover.txt"
exit $result
