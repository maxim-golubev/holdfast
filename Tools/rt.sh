#!/bin/zsh
# Real-device test helpers. Source it: `source Tools/rt.sh`. The app is launched from this shell so it runs
# under the terminal's Screen Recording / Microphone grants.
RT_ROOT="${0:A:h:h}"
RT_APP="$RT_ROOT/build/Build/Products/Release/Holdfast.app"
RT_ID=com.maximgolubev.Holdfast
RT_LOG=~/Library/Logs/Holdfast/recordings.log

rt_quit() { osascript -e "tell application id \"$RT_ID\" to quit" 2>/dev/null; for i in {1..40}; do pgrep -f "Release/Holdfast.app" >/dev/null || return 0; sleep 0.5; done; echo "rt: app did not quit"; return 1 }
rt_launch() { # rt_launch <save-dir>
  mkdir -p "$1"; RT_DIR="$1"
  defaults write $RT_ID saveDirectory -string "$1"; defaults write $RT_ID showPreview -bool false
  nohup "$RT_APP/Contents/MacOS/Holdfast" > "$1/app.out" 2>&1 &
  RT_PID=$!; sleep 4
}
rt_start() { osascript -e 'with timeout of 20 seconds' -e "tell application id \"$RT_ID\" to record screen numbered ${1:-1}" -e 'end timeout' }
rt_stop() { osascript -e "tell application id \"$RT_ID\" to stop recording" }
rt_wait_final() { # waits until no temporary recording/mixing file is left
  for i in {1..${1:-120}}; do sleep 1; ls "$RT_DIR" | grep -q -E '\.(recording|mixing)\.' || return 0; done; echo "rt: still not final"; return 1 }
rt_tracks() { ls "$RT_DIR" | grep -E "\.(mp4|m4a|mov)$" | while read n; do f="$RT_DIR/$n"; echo "== ${f:t}"; ffprobe -v error -show_entries stream=index,codec_type,codec_name,sample_rate,duration -of compact "$f" 2>&1; done }
rt_levels() { # rt_levels <file> <audio-track-index>: level per 2 s, -180 = digital silence
  ffmpeg -hide_banner -loglevel error -y -i "$1" -map 0:a:$2 -vn -ac 1 -ar 8000 -f s16le /tmp/_rt.raw || return 1
  python3 -c "
import numpy as np
x=np.fromfile('/tmp/_rt.raw',dtype=np.int16).astype(np.float32)/32768; w=16000
o=[(-180.0 if (r:=np.sqrt((x[i:i+w]**2).mean()))==0 else 20*np.log10(r)) for i in range(0,len(x)-w+1,w)]
print(' '.join('%.0f'%v for v in o))"
}
