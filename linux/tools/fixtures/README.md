# Test fixtures

`nonref-thin-line-640x360.h264`: exactly what darpan-capture (PR #36) sent, as Annex B, for a 640×360
screen that X re-damages in full at 60 Hz while a 10×2 line toggles 5 times a second. The line falls
between the sampled rows, so the stream has non-reference P frames: 139 pictures, one IDR (the
first), 68 non-reference. FFmpeg's H.264 decoder decodes all of them with no warnings.
`nonref-thin-line-640x360.json` lists which pictures are non-reference. `…-last.png` is FFmpeg's
decode of the last picture, so another decoder (VideoToolbox, WebCodecs) can be compared with it.
