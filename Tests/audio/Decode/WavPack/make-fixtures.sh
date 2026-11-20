#!/bin/sh
# Remakes the WavPack fixtures beside this script from make-sources.py's WAV
# and DSF sources. Needs the wavpack tool (brew install wavpack). Run it only
# to change the fixtures, and commit what it writes. Small blocks give each
# file several, so a seek crosses blocks.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 -I "$here/make-sources.py" "$work"
pack() { name=$1; shift; wavpack -q -y --blocksize=1024 "$@" "$work/$name" -o "$here/${name%.*}.wv"; }
pack s16.wav -h -w "Title=Triangle" -w "Artist=Vibe Tests" -w "Album=Fixtures" -w "Track=3/9" -w "Year=2026" \
    --write-binary-tag "Cover Art (Front)=@$work/cover.png"
pack s24.wav -x
pack s20.wav -f
pack s32.wav -hh
pack f32.wav
pack u8.wav
pack surround.wav
pack dsd.dsf
pack dsd256.dsf
# A hybrid file plays its lossy half alone. Its correction file is kept beside
# it, so a later version can test the lossless decode.
wavpack -q -y --blocksize=1024 -b4 -c "$work/s16.wav" -o "$here/hybrid.wv"
# A file that never states its length: the encoder reads a pipe and ignores
# the WAV's length, and writes to a pipe, so it cannot go back to the first
# block. The open then reads the last blocks.
cat "$work/s16.wav" | wavpack -q -y --blocksize=1024 -i - -o - > "$here/unsized.wv" 2> /dev/null
