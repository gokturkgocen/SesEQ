"""Diagnose the offset between my mel and essentia's, by matching a single frame
through essentia's individual algorithms vs my numpy steps."""
import numpy as np
import essentia.standard as es

SR, FRAME, HOP, NBANDS = 16000, 512, 256, 96
audio = es.MonoLoader(filename="test_16k.wav", sampleRate=SR)()

# Grab one representative frame from the middle
frames = list(es.FrameGenerator(audio, frameSize=FRAME, hopSize=HOP, startFromZero=True))
fr = frames[5000]

# --- Essentia's exact internal chain (mirror TensorflowInputMusiCNN) ---
w_norm = es.Windowing(type="hann", normalized=True)
w_raw  = es.Windowing(type="hann", normalized=False)
spec   = es.Spectrum()

# What window does essentia produce? Apply to an impulse-ish to inspect gain
ones = np.ones(FRAME, dtype=np.float32)
print("essentia hann normalized=True  sum:", float(np.sum(w_norm(ones))))
print("essentia hann normalized=False sum:", float(np.sum(w_raw(ones))))
print("numpy hanning(512) periodic   sum:", float(np.sum(np.hanning(FRAME+1)[:-1])))
print("numpy hanning(512) symmetric  sum:", float(np.sum(np.hanning(FRAME))))

# Essentia mel for this frame (ground truth)
tfin = es.TensorflowInputMusiCNN()
ess = tfin(fr)
print("\nessentia mel[0:5]:", ess[:5])
print("essentia mel range:", float(ess.min()), float(ess.max()))

# Essentia spectrum for this frame
sp_norm = spec(w_norm(fr))
sp_raw  = spec(w_raw(fr))
print("\nessentia spectrum(normalized win) [1:4]:", sp_norm[1:4])
print("essentia spectrum(raw win)        [1:4]:", sp_raw[1:4])

# My spectrum variants
for wname, win in [("periodic", np.hanning(FRAME+1)[:-1]),
                   ("symmetric", np.hanning(FRAME))]:
    my_sp = np.abs(np.fft.rfft(fr.astype(np.float64) * win))
    print(f"my spectrum ({wname}) [1:4]:", my_sp[1:4],
          " ratio to ess_norm:", (sp_norm[1:4] / (my_sp[1:4] + 1e-12)))
