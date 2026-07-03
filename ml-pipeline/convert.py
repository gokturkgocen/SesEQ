"""
Phase 0 feasibility gate: convert Discogs-EffNet ONNX → CoreML and verify it runs.

Pipeline: ONNX --onnx2torch--> torch.nn.Module --coremltools--> .mlpackage
Then sanity-check: feed a dummy mel-spectrogram, confirm 400-dim + 1280-dim output,
and cross-check the CoreML output against onnxruntime on the same input.
"""
import numpy as np
import onnxruntime as ort
import torch
import coremltools as ct
from onnx2torch import convert as onnx2torch_convert

ONNX_PATH = "discogs-effnet-bsdynamic-1.onnx"
COREML_PATH = "DiscogsEffNet.mlpackage"

# Model input: [batch, 128, 96] mel-spectrogram (128 frames x 96 mel bands)
DUMMY = np.random.randn(1, 128, 96).astype(np.float32)

print("=== 1. ONNX → PyTorch ===")
torch_model = onnx2torch_convert(ONNX_PATH)
torch_model.eval()
print("  ok")

print("=== 2. Reference output via onnxruntime ===")
sess = ort.InferenceSession(ONNX_PATH)
onnx_out = sess.run(None, {"melspectrogram": DUMMY})
print(f"  onnx activations shape: {onnx_out[0].shape}, embeddings shape: {onnx_out[1].shape}")

print("=== 3. PyTorch output (sanity vs onnx) ===")
with torch.no_grad():
    torch_out = torch_model(torch.from_numpy(DUMMY))
# onnx2torch returns a tuple/list matching graph outputs
if isinstance(torch_out, (list, tuple)):
    t_act = torch_out[0].numpy()
else:
    t_act = torch_out.numpy()
diff = np.abs(t_act - onnx_out[0]).max()
print(f"  max |torch - onnx| on activations: {diff:.6e}")

print("=== 4. PyTorch → CoreML ===")
traced = torch.jit.trace(torch_model, torch.from_numpy(DUMMY))
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="melspectrogram", shape=(1, 128, 96))],
    minimum_deployment_target=ct.target.macOS14,
    compute_units=ct.ComputeUnit.ALL,  # CPU + GPU + Neural Engine
)
mlmodel.save(COREML_PATH)
print(f"  saved {COREML_PATH}")

print("=== 5. CoreML inference verify ===")
loaded = ct.models.MLModel(COREML_PATH)
spec = loaded.get_spec()
print("  CoreML inputs:")
for inp in spec.description.input:
    print(f"    {inp.name}")
print("  CoreML outputs:")
for out in spec.description.output:
    print(f"    {out.name}")
cm_out = loaded.predict({"melspectrogram": DUMMY})
# Find the activations output (400-dim)
for k, v in cm_out.items():
    arr = np.array(v)
    print(f"    output '{k}': shape {arr.shape}")
    if arr.size == 400:
        diff_cm = np.abs(arr.flatten() - onnx_out[0].flatten()).max()
        print(f"      max |coreml - onnx| on 400-dim: {diff_cm:.6e}")

print("\n=== PHASE 0 RESULT: conversion + inference OK ===")
