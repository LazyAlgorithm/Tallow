#!/usr/bin/env python3
"""Writes a small rigged, animated GLB (a waving tentacle) in the same form Blender exports:
one skinned mesh with JOINTS_0 / WEIGHTS_0, a joint chain with inverse bind matrices, and two clips.
It exists to exercise skinning without needing a modelling tool.

Usage: make_rigged_sample.py <output.glb>
"""
import json, math, struct, sys

SEGMENTS, RINGS, JOINTS, LENGTH = 10, 24, 6, 3.0
bone = LENGTH / (JOINTS - 1)

positions, normals, colors, joints, weights, indices = [], [], [], [], [], []
for r in range(RINGS + 1):
    y = LENGTH * r / RINGS
    radius = 0.28 * (1 - 0.75 * r / RINGS)
    f = y / bone
    j0 = min(int(f), JOINTS - 1); j1 = min(j0 + 1, JOINTS - 1); w1 = f - j0 if j1 != j0 else 0.0
    shade = r / RINGS
    for s in range(SEGMENTS):
        a = s / SEGMENTS * math.tau
        positions.append((math.cos(a) * radius, y, math.sin(a) * radius))
        normals.append((math.cos(a), 0.2, math.sin(a)))
        stripe = 0.82 if (r // 2) % 2 else 1.0
        colors.append((pow((0.25 + 0.5 * shade) * stripe, 2.2), pow(0.55 * stripe, 2.2), pow((0.45 - 0.2 * shade) * stripe, 2.2), 1.0))
        joints.append((j0, j1, 0, 0)); weights.append((1 - w1, w1, 0.0, 0.0))
for r in range(RINGS):
    for s in range(SEGMENTS):
        a = r * SEGMENTS + s; b = r * SEGMENTS + (s + 1) % SEGMENTS; c = a + SEGMENTS; d = b + SEGMENTS
        indices += [a, c, b, b, c, d]  # counter-clockwise from outside

def quat_z(deg, x_deg=0.0):
    hz, hx = math.radians(deg) / 2, math.radians(x_deg) / 2
    qz = (0, 0, math.sin(hz), math.cos(hz)); qx = (math.sin(hx), 0, 0, math.cos(hx))
    return (qz[3] * qx[0] + qz[0] * qx[3] + qz[1] * qx[2] - qz[2] * qx[1],
            qz[3] * qx[1] - qz[0] * qx[2] + qz[1] * qx[3] + qz[2] * qx[0],
            qz[3] * qx[2] + qz[0] * qx[1] - qz[1] * qx[0] + qz[2] * qx[3],
            qz[3] * qx[3] - qz[0] * qx[0] - qz[1] * qx[1] - qz[2] * qx[2])

chunks, views, accessors = [], [], []
def add(data, comp, kind, count, target=None, mn=None, mx=None):
    offset = sum(len(c) for c in chunks)
    pad = (-len(data)) % 4
    chunks.append(data + b'\0' * pad)
    view = {"buffer": 0, "byteOffset": offset, "byteLength": len(data)}
    if target: view["target"] = target
    views.append(view)
    acc = {"bufferView": len(views) - 1, "componentType": comp, "count": count, "type": kind}
    if mn: acc["min"], acc["max"] = mn, mx
    accessors.append(acc)
    return len(accessors) - 1

n = len(positions)
a_pos = add(b''.join(struct.pack('<3f', *p) for p in positions), 5126, "VEC3", n, 34962,
            [min(p[i] for p in positions) for i in range(3)], [max(p[i] for p in positions) for i in range(3)])
a_nrm = add(b''.join(struct.pack('<3f', *v) for v in normals), 5126, "VEC3", n, 34962)
a_col = add(b''.join(struct.pack('<4f', *v) for v in colors), 5126, "VEC4", n, 34962)
a_jnt = add(b''.join(struct.pack('<4H', *v) for v in joints), 5123, "VEC4", n, 34962)
a_wgt = add(b''.join(struct.pack('<4f', *v) for v in weights), 5126, "VEC4", n, 34962)
a_idx = add(struct.pack('<%dI' % len(indices), *indices), 5125, "SCALAR", len(indices), 34963)
ibm = b''
for j in range(JOINTS):  # bind pose: joint j sits at height j * bone, so its inverse moves it back down
    ibm += struct.pack('<16f', 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, -j * bone, 0, 1)
a_ibm = add(ibm, 5126, "MAT4", JOINTS)

animations = []
def clip(name, duration, amplitude, twist):
    keys = 13
    times = [duration * k / (keys - 1) for k in range(keys)]
    a_time = add(struct.pack('<%df' % keys, *times), 5126, "SCALAR", keys, None, [0.0], [duration])
    samplers, channels = [], []
    for j in range(JOINTS):
        data = b''
        for t in times:
            phase = t / duration * math.tau - j * 0.9
            data += struct.pack('<4f', *quat_z(amplitude * math.sin(phase) * (0.4 + j * 0.25), twist * math.cos(phase) * j * 0.3))
        a_rot = add(data, 5126, "VEC4", keys)
        samplers.append({"input": a_time, "output": a_rot, "interpolation": "LINEAR"})
        channels.append({"sampler": j, "target": {"node": 1 + j, "path": "rotation"}})
    animations.append({"name": name, "samplers": samplers, "channels": channels})
clip("Idle", 4.0, 6, 3)
clip("Wave", 1.6, 22, 12)

nodes = [{"name": "Tentacle", "mesh": 0, "skin": 0}]
for j in range(JOINTS):
    node = {"name": "Bone.%03d" % j, "translation": [0, 0 if j == 0 else bone, 0]}
    if j + 1 < JOINTS: node["children"] = [2 + j]
    nodes.append(node)
doc = {
    "asset": {"version": "2.0", "generator": "Tallow make_rigged_sample"},
    "scene": 0, "scenes": [{"nodes": [0, 1]}], "nodes": nodes,
    "skins": [{"joints": list(range(1, 1 + JOINTS)), "inverseBindMatrices": a_ibm, "skeleton": 1}],
    "materials": [{"pbrMetallicRoughness": {"baseColorFactor": [1, 1, 1, 1], "metallicFactor": 0, "roughnessFactor": 0.8}}],
    "meshes": [{"primitives": [{"attributes": {"POSITION": a_pos, "NORMAL": a_nrm, "COLOR_0": a_col, "JOINTS_0": a_jnt, "WEIGHTS_0": a_wgt}, "indices": a_idx, "material": 0}]}],
    "animations": animations, "accessors": accessors, "bufferViews": views,
    "buffers": [{"byteLength": sum(len(c) for c in chunks)}],
}
text = json.dumps(doc, separators=(',', ':')).encode(); text += b' ' * (-len(text) % 4)
binary = b''.join(chunks)
with open(sys.argv[1] if len(sys.argv) > 1 else 'rigged_sample.glb', 'wb') as f:
    f.write(struct.pack('<4sII', b'glTF', 2, 12 + 8 + len(text) + 8 + len(binary)))
    f.write(struct.pack('<I4s', len(text), b'JSON')); f.write(text)
    f.write(struct.pack('<I4s', len(binary), b'BIN\0')); f.write(binary)
print('rigged sample:', n, 'vertices,', JOINTS, 'joints, 2 clips')
