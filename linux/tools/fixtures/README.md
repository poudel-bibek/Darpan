# Test fixtures

`nonref-thin-line-640x360.h264`: exactly what darpan-capture (PR #36) sent, as Annex B, for a 640×360
screen that X re-damages in full at 60 Hz while a 10×2 line toggles 5 times a second. The line falls
between the sampled rows, so the stream has non-reference P frames: 139 pictures, one IDR (the
first), 68 non-reference. FFmpeg's H.264 decoder decodes all of them with no warnings.
`nonref-thin-line-640x360.json` lists which pictures are non-reference. `…-last.png` is FFmpeg's
decode of the last picture, so another decoder (VideoToolbox, WebCodecs) can be compared with it.

`vulkan-640x360.h264`: what darpan-capture sends through Vulkan Video (PR #58), made by
`linux/tools/make_fixture.py`. The 640×360 screen is repainted in full at 60 Hz. A box moves for a
second, rests for 1.5 s, then moves again, and a 10×2 line between the sampled rows toggles 5 times a
second. That makes 159 pictures: one IDR (the first), reference frames with motion, and 14
non-reference probes. FFmpeg's decoder (GStreamer's avdec_h264) decodes all of them with no warnings;
the last picture is 40.5 dB PSNR against the screen. `…json` lists the IDR and non-reference
pictures, and `…-last.png` is that decode of the last picture.
