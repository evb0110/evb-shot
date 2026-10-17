#!/usr/bin/env python3
"""Independent fixture verification. Requires ffmpeg/ffprobe for development only."""
import array
import json
import math
import pathlib
import subprocess
import sys

folder = pathlib.Path(sys.argv[1])


def probe(name):
    return json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(folder / name)]))


def essence(name):
    return subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(folder / name), '-map', '0:v:0', '-c', 'copy', '-f', 'hash', '-hash', 'sha256', '-']).decode().strip()


mixed = probe('selfie-and-mixed-audio.mov')
video = [s for s in mixed['streams'] if s['codec_type'] == 'video']
audio = [s for s in mixed['streams'] if s['codec_type'] == 'audio']
assert len(video) == len(audio) == 1
assert (video[0]['width'], video[0]['height'], video[0]['nb_frames'], video[0]['r_frame_rate']) == (640, 360, '60', '30/1')
film = probe('24-fps.mov')
film_video = [s for s in film['streams'] if s['codec_type'] == 'video']
assert len(film_video) == 1
assert (film_video[0]['width'], film_video[0]['height'], film_video[0]['nb_frames'], film_video[0]['r_frame_rate']) == (320, 180, '48', '24/1')
print('PASS selected 24 FPS export: 320 x 180, 48 frames, 24/1 encoded frame rate')
frame = subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(folder / 'selfie-and-mixed-audio.mov'), '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'])
offset = (295 * 640 + 558) * 3
r, g, b = frame[offset:offset+3]
assert r > 200 and 70 < g < 160 and b < 80, ('Selfie corner pixel', r, g, b)
offset = (50 * 640 + 50) * 3
r, g, b = frame[offset:offset+3]
assert r < 70 and b > r, ('Screen background pixel', r, g, b)
print('PASS decoded video contains the composited selfie fixture in the bottom-right corner')
pcm = subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(folder / 'selfie-and-mixed-audio.mov'), '-map', '0:a:0', '-af', 'pan=mono|c0=c0', '-ar', '48000', '-f', 'f32le', '-'])
samples = array.array('f', pcm)
for frequency in [440, 880]:
    # Exclude AAC start/end padding; measure each independently generated source.
    values = samples[4800:86400]
    real = sum(v * math.cos(2 * math.pi * frequency * i / 48000) for i, v in enumerate(values))
    imaginary = sum(v * math.sin(2 * math.pi * frequency * i / 48000) for i, v in enumerate(values))
    amplitude = 2 * math.hypot(real, imaginary) / len(values)
    assert .09 < amplitude < .19, (frequency, amplitude)
    print(f'PASS mixed audio contains {frequency} Hz source, measured amplitude {amplitude:.4f}')
assert not [s for s in probe('silent.mov')['streams'] if s['codec_type'] == 'audio']
assert essence('selfie-and-mixed-audio.mov') == essence('silent.mov'), 'Muting changed compressed video samples'
for name in ['audio-only.m4a', 'audio-only-mixed.m4a']:
    streams = probe(name)['streams']
    assert len(streams) == 1 and streams[0]['codec_type'] == 'audio' and streams[0]['codec_name'] == 'aac'
static = probe('static-desktop.mov')
assert float(static['format']['duration']) > .65
assert int(static['streams'][0]['nb_frames']) >= 18
print('PASS native dimensions/FPS, 60 encoded frames, one mixed audio track, silent video with identical compressed video, audio-only outputs, static desktop clock')
