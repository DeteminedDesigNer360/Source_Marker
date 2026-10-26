# -*- coding: utf-8 -*-
import os, subprocess, sys, time
ROOT = r'C:\Users\Frisk\Documents\Source_Marker_United'
FF = os.path.join(ROOT, 'ffmpeg.exe')
sec = int(sys.argv[1])
out = os.path.join(ROOT, 'reference', '标尺素材-%dmin-30fps.mp4' % (sec // 60))
vf = ("drawtext=fontfile='C\\:/Windows/Fonts/consola.ttf':text='%{pts\\:hms}':fontsize=150:fontcolor=white:x=(w-text_w)/2:y=180"
      ",drawtext=fontfile='C\\:/Windows/Fonts/consola.ttf':text='frame %{eif\\:n\\:d}':fontsize=64:fontcolor=yellow:x=(w-text_w)/2:y=400")
cmd = [FF, '-y', '-f', 'lavfi', '-i', 'color=c=0x14141a:s=1280x720:r=30:d=%d' % sec,
       '-vf', vf, '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '32',
       '-pix_fmt', 'yuv420p', '-movflags', '+faststart', out]
t0 = time.time()
r = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace')
print('exit=%d  %.1fs  err_tail=%s' % (r.returncode, time.time() - t0, (r.stderr or '')[-400:]))
print('size=%.2f MB' % (os.path.getsize(out) / 1048576.0) if os.path.exists(out) else 'MISSING')
