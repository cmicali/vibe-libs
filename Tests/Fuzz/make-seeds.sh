#!/bin/bash
# Writes the fuzz targets' seeds into Tests/Fuzz/Seeds, from a sine tone and a
# small generated picture, so no seed is anyone's recording. Each is a valid
# file of its target's format, tagged, and small enough that a run mutates it
# fast. Needs `brew install ffmpeg flac`, and macOS's sips and iconv. The
# Monkey's Audio seeds need the SDK's own encoder, `mac`, whose path MAC
# names (third_party/monkeys_audio/AGENTS.md says how to build it). The text
# seeds are written by hand.
# Re-run it only to change the seeds, then commit them.
set -euo pipefail
: "${MAC:?set MAC to the path of the Monkey's Audio SDK's mac encoder}"

here="$(cd "$(dirname "$0")" && pwd)"
seeds="$here/Seeds"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }

tone() { ff -f lavfi -i "sine=frequency=440:sample_rate=$1:duration=$2" -ac 1 "$work/tone-$1.wav"; }
tone 8000 0.05
tone 44100 0.05
tone 48000 0.05

# A 16 px cover, as PNG and JPEG, which the art seeds also take.
ff -f lavfi -i "testsrc=size=16x16:rate=1" -frames:v 1 "$work/cover.png"
ff -i "$work/cover.png" -q:v 8 "$work/cover.jpg"

tags=(-metadata title="Fuzz Tone" -metadata artist="Seed Artist" -metadata album="Seed Album"
      -metadata album_artist="Seed Album Artist" -metadata genre="Test" -metadata date="2026"
      -metadata track="3/9" -metadata disc="1/2" -metadata composer="Seed Composer"
      -metadata comment="seed" -metadata TBPM=120 -metadata BPM=120 -metadata initialkey=8A
      -metadata REPLAYGAIN_TRACK_GAIN="-6.5 dB" -metadata REPLAYGAIN_TRACK_PEAK=0.9
      -metadata MUSICBRAINZ_ALBUMID=00000000-0000-0000-0000-000000000000 -metadata ISRC=XX0000000000)

with_cover() { ff -i "$1" -i "$work/cover.$2" -map 0:a -map 1:v -c:v copy -disposition:v attached_pic "${@:4}" "$3"; }

rm -rf "$seeds"
mkdir -p "$seeds"/{tags-flac,tags-mp3,tags-m4a,tags-wav,tags-aiff,tags-ogg,tags-opus,tags-wv,tags-ape,flac-cue,cue,m3u,art}

# FLAC: plain, tagged, with a picture, with a sheet as a comment, and with a
# binary CUESHEET block, which metaflac takes only for a 44.1 kHz stream.
ff -i "$work/tone-8000.wav" -c:a flac "$seeds/tags-flac/plain.flac"
ff -i "$work/tone-8000.wav" "${tags[@]}" -c:a flac "$seeds/tags-flac/tagged.flac"
with_cover "$work/tone-8000.wav" png "$seeds/tags-flac/cover.flac" "${tags[@]}" -c:a flac
sheet=$'PERFORMER "Seed Artist"\nTITLE "Seed Album"\nFILE "tone.flac" WAVE\n  TRACK 01 AUDIO\n    TITLE "One"\n    INDEX 01 00:00:00\n  TRACK 02 AUDIO\n    TITLE "Two"\n    INDEX 00 00:00:01\n    INDEX 01 00:00:02\n'
ff -i "$work/tone-8000.wav" -metadata CUESHEET="$sheet" -c:a flac "$seeds/tags-flac/sheet-comment.flac"
ff -i "$work/tone-44100.wav" -c:a flac "$seeds/tags-flac/sheet-block.flac"
printf 'FILE "cd.wav" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n  TRACK 02 AUDIO\n    INDEX 00 00:00:01\n    INDEX 01 00:00:02\n' > "$work/cd.cue"
metaflac --import-cuesheet-from="$work/cd.cue" "$seeds/tags-flac/sheet-block.flac"
cp "$seeds/tags-flac/sheet-comment.flac" "$seeds/tags-flac/sheet-block.flac" "$seeds/flac-cue/"

# Without the padding block, every FLAC seed is a few hundred bytes.
for f in "$seeds"/tags-flac/*.flac "$seeds"/flac-cue/*.flac; do
    metaflac --remove --block-type=PADDING --dont-use-padding "$f"
done
# A FLAC behind an ID3v2 tag, which the sheet reader skips.
{ printf 'ID3\x04\x00\x00\x00\x00\x00\x00'; cat "$seeds/tags-flac/sheet-comment.flac"; } > "$seeds/flac-cue/id3-before.flac"

# MP3: ID3v2.4, ID3v2.3 with a picture, and ID3v1 alone.
ff -i "$work/tone-8000.wav" "${tags[@]}" -c:a libmp3lame -b:a 8k "$seeds/tags-mp3/id3v24.mp3"
with_cover "$work/tone-8000.wav" jpg "$seeds/tags-mp3/id3v23-cover.mp3" "${tags[@]}" -c:a libmp3lame -b:a 8k -id3v2_version 3
ff -i "$work/tone-8000.wav" "${tags[@]}" -c:a libmp3lame -b:a 8k -id3v2_version 0 -write_id3v1 1 "$seeds/tags-mp3/id3v1.mp3"

# MP4: AAC with a cover, and ALAC.
with_cover "$work/tone-8000.wav" png "$seeds/tags-m4a/aac-cover.m4a" "${tags[@]}" -c:a aac -b:a 16k
ff -i "$work/tone-8000.wav" "${tags[@]}" -c:a alac "$seeds/tags-m4a/alac.m4a"

# WAV with a RIFF INFO list, and AIFF with an ID3v2 chunk.
ff -i "$work/tone-8000.wav" "${tags[@]}" -c:a pcm_s16le "$seeds/tags-wav/info.wav"
ff -i "$work/tone-8000.wav" -c:a pcm_s16le -bitexact "$seeds/tags-wav/plain.wav"
ff -i "$work/tone-8000.wav" "${tags[@]}" -c:a pcm_s16be -write_id3v2 1 "$seeds/tags-aiff/id3.aiff"
ff -i "$work/tone-8000.wav" -c:a pcm_s16be "$seeds/tags-aiff/plain.aiff"

# Ogg: Vorbis, and Opus under both extensions.
ff -i "$work/tone-8000.wav" "${tags[@]}" -c:a vorbis -strict -2 -ac 2 "$seeds/tags-ogg/vorbis.ogg"
ff -i "$work/tone-48000.wav" "${tags[@]}" -c:a libopus -b:a 8k "$seeds/tags-opus/tagged.opus"
cp "$seeds/tags-opus/tagged.opus" "$seeds/tags-ogg/opus.ogg"

# WavPack: plain, and tagged with APEv2. ffmpeg writes no cover, so a cover's
# seed is audio/Decode's fixture, which the wavpack tool made.
ff -i "$work/tone-8000.wav" -c:a wavpack "$seeds/tags-wv/plain.wv"
ff -i "$work/tone-8000.wav" "${tags[@]}" -c:a wavpack "$seeds/tags-wv/tagged.wv"
cp "$here/../audio/Decode/WavPack/s16.wv" "$seeds/tags-wv/cover.wv"

# Monkey's Audio: tagged at Normal, and at Extra High behind an ID3v2 tag,
# which the SDK and TagLib both skip.
"$MAC" "$work/tone-8000.wav" "$seeds/tags-ape/tagged.ape" -c2000 \
    -t "Title=Fuzz Tone|Artist=Seed Artist|Album=Seed Album|Year=2026|Track=3|Genre=Test" >/dev/null
"$MAC" "$work/tone-44100.wav" "$work/plain.ape" -c4000 >/dev/null
{ printf 'ID3\x04\x00\x00\x00\x00\x00\x00'; cat "$work/plain.ape"; } > "$seeds/tags-ape/id3-before.ape"

# Pictures as a file or a tag carries them.
cp "$work/cover.png" "$work/cover.jpg" "$seeds/art/"
ff -i "$work/cover.png" "$seeds/art/cover.gif"
ff -i "$work/cover.png" "$seeds/art/cover.bmp"
ff -i "$work/cover.png" "$seeds/art/cover.tiff"
sips -s format heic "$work/cover.png" --out "$seeds/art/cover.heic" >/dev/null

# CUE sheets: a typical one, one in UTF-16 with a BOM, and Latin-1.
cat > "$seeds/cue/album.cue" <<'CUE'
REM GENRE Test
REM DATE 2026
PERFORMER "Seed Artist"
TITLE "Seed Album"
FILE "Seed Album.flac" WAVE
  TRACK 01 AUDIO
    TITLE "One"
    PERFORMER "Seed Artist"
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    TITLE "Two"
    INDEX 00 03:58:70
    INDEX 01 04:00:00
  TRACK 03 AUDIO
    TITLE "Three"
    INDEX 01 08:12:33
FILE "Bonus.wav" WAVE
  TRACK 04 AUDIO
    INDEX 01 00:00:00
CUE
printf 'FILE C:\\Music\\mix.mp3 MP3\r\n  TRACK 1 AUDIO\r\n    INDEX 1 0:0:0\r\n  TRACK 2 AUDIO\r\n    INDEX 1 99:59:74\r\n' > "$seeds/cue/windows.cue"
iconv -f UTF-8 -t UTF-16 "$seeds/cue/album.cue" > "$seeds/cue/utf16.cue"
printf 'TITLE "Caf\xe9"\nFILE "caf\xe9.wav" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n' > "$seeds/cue/latin1.cue"

# M3U: extended, plain with Windows paths, UTF-16, URLs, and this writer's cue lines.
cat > "$seeds/m3u/extended.m3u8" <<'M3U'
#EXTM3U
#EXTINF:123,Seed Artist - One
../Music/One.flac
#EXTINF:-1,Stream
http://example.com/stream
file:///Users/Shared/Two%20Two.mp3
#EXTVLCOPT:start-time=4
#EXTVLCOPT:stop-time=8.5
#VIBE-CUE:2,300,637,Two,Seed%20Artist,file:///Users/Shared/Album.cue
/Users/Shared/Album.flac
M3U
printf 'C:\\Music\\One.mp3\r\n.\\Two.flac\r\n\r\n..\\..\\Three.m4a\r\n' > "$seeds/m3u/windows.m3u"
iconv -f UTF-8 -t UTF-16 "$seeds/m3u/extended.m3u8" > "$seeds/m3u/utf16.m3u"

du -sh "$seeds"
