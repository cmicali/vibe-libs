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
# Each DSD source stays beside its .wv, so a test decodes the same DSD from
# both containers.
for source in dsd dsd-msb dsd128-48k dsd256 dsd512 dsd-surround dsd-odd; do
    pack "$source.dsf"
    cp "$work/$source.dsf" "$here/"
done
# Damaged DSD: no bit order in its config, and a hybrid flag no encoder writes.
python3 -I "$here/make-sources.py" --damage no-qmode "$here/dsd.wv" "$here/dsd-no-qmode.wv"
python3 -I "$here/make-sources.py" --damage hybrid "$here/dsd.wv" "$here/dsd-hybrid.wv"
# A hybrid file and its correction file, which together decode lossless.
wavpack -q -y --blocksize=1024 -b4 -c "$work/s16.wav" -o "$here/hybrid.wv"
# Another song's correction file, of the same length and blocks: s16's
# samples negated. Only its checksums tell it from hybrid.wvc.
wavpack -q -y --blocksize=1024 -b4 -c "$work/negated.wav" -o "$work/negated.wv"
mv "$work/negated.wvc" "$here/negated.wvc"
# A song whose last two blocks are digital silence, packed at two rates.
# Each rate's .wvc pairs with the other's .wv block for block, and the silent
# blocks decode the same either way, so only a block with sound tells
# fade-b3.wvc from fade.wvc.
wavpack -q -y --blocksize=1024 -b4 -c "$work/fade.wav" -o "$here/fade.wv"
wavpack -q -y --blocksize=1024 -b3 -c "$work/fade.wav" -o "$work/fade-b3.wv"
mv "$work/fade-b3.wvc" "$here/fade-b3.wvc"
# A hybrid pair of 15 s, each file four of a read-ahead's 256 KB blocks long,
# so a read can wait in the third of either while the open's check reads
# only the first, the second, and the last.
wavpack -q -y --blocksize=1024 -b4 -c "$work/long.wav" -o "$here/long.wv"
# A file that never states its length: the encoder reads a pipe and ignores
# the WAV's length, and writes to a pipe, so it cannot go back to the first
# block. The open then reads the last blocks.
cat "$work/s16.wav" | wavpack -q -y --blocksize=1024 -i - -o - > "$here/unsized.wv" 2> /dev/null
# The tag writer's file with an APE tag of another tool's making: ffmpeg's,
# the fuzz seed tags-wv/plain.wv, which make-seeds.sh writes.
cp "$here/../../../Fuzz/Seeds/tags-wv/plain.wv" "$here/ffmpeg.wv"
