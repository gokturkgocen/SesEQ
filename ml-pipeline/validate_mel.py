"""
Phase 1 validation: prove a from-scratch mel recipe (the one we'll port to Swift)
matches Essentia's TensorflowInputMusiCNN, and that the full chain
(audio -> mel -> CoreML) produces sensible genre output on real music.

Two checks:
  A. NUMERICAL: my numpy mel  vs  essentia mel  (must be close)
  B. END-TO-END: essentia mel -> CoreML -> top genres  (must be sensible, not garbage)
  C. EQUIVALENCE: my numpy mel -> CoreML  vs  essentia mel -> CoreML  (same top genres)
"""
import json
import numpy as np
import coremltools as ct
import essentia.standard as es

WAV = "test_16k.wav"
SR = 16000
FRAME = 512
HOP = 256
NBANDS = 96
PATCH = 128  # frames per model input

# ---------- Load 400 style labels ----------
meta = json.load(open("discogs-effnet-metadata.json"))
def find_classes(o):
    if isinstance(o, list) and len(o) == 400 and all(isinstance(x, str) for x in o): return o
    if isinstance(o, dict):
        for v in o.values():
            r = find_classes(v)
            if r: return r
    if isinstance(o, list):
        for v in o:
            r = find_classes(v)
            if r: return r
    return None
LABELS = find_classes(meta)

# ---------- Load audio (16k mono) ----------
audio = es.MonoLoader(filename=WAV, sampleRate=SR)()
print(f"audio: {len(audio)} samples = {len(audio)/SR:.1f}s")

# ---------- A. Essentia ground-truth mel ----------
tfin = es.TensorflowInputMusiCNN()
ess_mels = []
for frame in es.FrameGenerator(audio, frameSize=FRAME, hopSize=HOP, startFromZero=True):
    ess_mels.append(tfin(frame))
ess_mels = np.array(ess_mels, dtype=np.float32)  # [num_frames, 96]
print(f"essentia mel: {ess_mels.shape}")

# ---------- B. My numpy recipe (what I'll port to Swift) ----------
# Build a mel filterbank matching essentia MelBands(slaneyMel, unit_tri, 0-8000Hz).
def hz_to_mel_slaney(f):
    f = np.asarray(f, dtype=np.float64)
    mel = np.where(f < 1000, f / (200.0/3),
                   15.0 + np.log(f/1000.0) / (np.log(6.4)/27.0))
    return mel
def mel_to_hz_slaney(m):
    m = np.asarray(m, dtype=np.float64)
    return np.where(m < 15.0, m * (200.0/3),
                    1000.0 * np.exp((m - 15.0) * (np.log(6.4)/27.0)))

def build_mel_fb(n_bands=NBANDS, n_fft=FRAME, sr=SR, fmin=0.0, fmax=8000.0):
    n_spec = n_fft // 2 + 1  # 257
    fft_freqs = np.linspace(0, sr/2, n_spec)
    mmin, mmax = hz_to_mel_slaney(fmin), hz_to_mel_slaney(fmax)
    mel_pts = np.linspace(mmin, mmax, n_bands + 2)
    hz_pts = mel_to_hz_slaney(mel_pts)
    fb = np.zeros((n_bands, n_spec), dtype=np.float64)
    for i in range(n_bands):
        lo, ctr, hi = hz_pts[i], hz_pts[i+1], hz_pts[i+2]
        for j, f in enumerate(fft_freqs):
            if lo <= f <= ctr and ctr > lo:
                fb[i, j] = (f - lo) / (ctr - lo)
            elif ctr < f <= hi and hi > ctr:
                fb[i, j] = (hi - f) / (hi - ctr)
    # unit_tri normalization: each triangle scaled to unit area (2/(hi-lo))
    for i in range(n_bands):
        lo, hi = hz_pts[i], hz_pts[i+2]
        if hi > lo:
            fb[i, :] *= 2.0 / (hi - lo)
    return fb.astype(np.float64)

# EXACT essentia TensorflowInputMusiCNN recipe (brute-force verified, max diff 0.0):
#   symmetric raw hann -> |rfft|^2 (POWER) -> unit_tri mel FB (96x257) -> log10(10000*x+1)
# We load the filterbank matrix extracted directly from essentia.MelBands via impulse responses.
MEL_FB = np.load("mel_filterbank_96x257.npy").astype(np.float64)  # [96, 257]
hann = np.hanning(FRAME).astype(np.float64)               # symmetric, sum=255.5, NOT normalized

def my_mel(audio):
    n = len(audio)
    frames = []
    start = 0
    while start + FRAME <= n:
        frames.append(audio[start:start+FRAME])
        start += HOP
    out = []
    for fr in frames:
        w = fr.astype(np.float64) * hann
        spec = np.abs(np.fft.rfft(w))   # magnitude, 257 bins
        power = spec * spec             # POWER spectrum (type='power')
        mel = MEL_FB @ power
        mel = np.log10(10000.0 * mel + 1.0)
        out.append(mel)
    return np.array(out, dtype=np.float32)

my_mels = my_mel(audio)
print(f"my mel:       {my_mels.shape}")

# Align lengths
n = min(len(ess_mels), len(my_mels))
ess_mels, my_mels = ess_mels[:n], my_mels[:n]
diff = np.abs(ess_mels - my_mels)
print(f"\n[A] mel diff:  max={diff.max():.4f}  mean={diff.mean():.4f}  "
      f"(essentia range {ess_mels.min():.2f}..{ess_mels.max():.2f})")
corr = np.corrcoef(ess_mels.flatten(), my_mels.flatten())[0,1]
print(f"    correlation: {corr:.5f}")

# ---------- CoreML predict helper ----------
model = ct.models.MLModel("DiscogsEffNet.mlpackage")
def predict_top(mels, k=8):
    # take overlapping 128-frame patches, average activations
    patches = []
    for s in range(0, len(mels) - PATCH + 1, PATCH // 2):
        patches.append(mels[s:s+PATCH])
    if not patches:
        patches = [np.pad(mels, ((0, PATCH-len(mels)), (0,0)))]
    acts = []
    for p in patches:
        inp = p.reshape(1, PATCH, NBANDS).astype(np.float32)
        out = model.predict({"melspectrogram": inp})
        acts.append(np.array(out["activations"]).flatten())
    avg = np.mean(acts, axis=0)
    idx = np.argsort(avg)[::-1][:k]
    return [(LABELS[i], float(avg[i])) for i in idx]

print("\n[B] END-TO-END (essentia mel -> CoreML), top genres:")
for name, p in predict_top(ess_mels):
    print(f"    {p:.3f}  {name}")

print("\n[C] EQUIVALENCE (my numpy mel -> CoreML), top genres:")
for name, p in predict_top(my_mels):
    print(f"    {p:.3f}  {name}")
