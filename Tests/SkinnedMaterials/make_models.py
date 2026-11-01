"""Makes the test models for Tests/SkinnedMaterials: a small rigged mesh in two parts with two materials, whose
textures arrive the three ways glTF allows (inside the .glb, as a data: address, and as a file beside the model).
Run it again only if the models need to change: python3 Tests/SkinnedMaterials/make_models.py"""
import base64, json, os, struct, zlib

HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "assets")

def png(rgba_rows):
    """A tiny PNG from rows of (r, g, b, a) tuples."""
    raw = b"".join(b"\x00" + bytes(c for px in row for c in px) for row in rgba_rows)
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    h, w = len(rgba_rows), len(rgba_rows[0])
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")

RED = png([[(255, 0, 0, 255), (200, 0, 0, 255)], [(150, 0, 0, 255), (100, 0, 0, 255)]])
FLAT_NORMAL = png([[(128, 128, 255, 255)] * 2] * 2)
GREEN = png([[(0, 255, 0, 255)] * 2] * 2)

def build(name, image_style):
    # Two quads (a "body" and an "armour" part), each skinned to one of two joints.
    positions, normals, uvs, joints, weights, indices = [], [], [], [], [], []
    for part in range(2):
        base = len(positions)
        y = part * 1.0
        for (x, yy, u, v) in [(0, 0, 0, 1), (1, 0, 1, 1), (1, 1, 1, 0), (0, 1, 0, 0)]:
            positions.append((x, y + yy, 0)); normals.append((0, 0, 1)); uvs.append((u, v))
            joints.append((part, 0, 0, 0)); weights.append((1, 0, 0, 0))
        indices.append([base, base + 1, base + 2, base, base + 2, base + 3])

    blob = bytearray()
    views, accessors = [], []
    def add(data, target=None):
        while len(blob) % 4: blob.append(0)
        views.append({"buffer": 0, "byteOffset": len(blob), "byteLength": len(data), **({"target": target} if target else {})})
        blob.extend(data)
        return len(views) - 1
    def accessor(fmt, values, kind, ctype, extra=None):
        data = b"".join(struct.pack(fmt, *v) for v in values)
        accessors.append({"bufferView": add(data, 34962), "componentType": ctype, "count": len(values), "type": kind, **(extra or {})})
        return len(accessors) - 1
    pos = accessor("<3f", positions, "VEC3", 5126, {"min": [0, 0, 0], "max": [1, 2, 0]})
    nor = accessor("<3f", normals, "VEC3", 5126)
    uv = accessor("<2f", uvs, "VEC2", 5126)
    jnt = accessor("<4H", joints, "VEC4", 5123)
    wgt = accessor("<4f", weights, "VEC4", 5126)
    idx = []
    for part in indices:
        data = struct.pack("<6I", *part)
        accessors.append({"bufferView": add(data, 34963), "componentType": 5125, "count": 6, "type": "SCALAR"})
        idx.append(len(accessors) - 1)
    ibm = accessor("<16f", [(1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1), (1,0,0,0, 0,1,0,0, 0,0,1,0, 0,-1,0,1)], "MAT4", 5126)

    images = []
    for i, data in enumerate([] if image_style == "none" else [RED, FLAT_NORMAL, GREEN]):
        if image_style == "embedded":
            images.append({"bufferView": add(data), "mimeType": "image/png"})
        elif image_style == "datauri":
            images.append({"uri": "data:image/png;base64," + base64.b64encode(data).decode()})
        else:
            file = f"{name}_image{i}.png"
            open(os.path.join(HERE, file), "wb").write(data)
            images.append({"uri": file})

    gltf = {
        "asset": {"version": "2.0", "generator": "Tallow test"},
        "scene": 0, "scenes": [{"nodes": [0, 2]}],
        "nodes": [{"name": "Root", "children": [1]}, {"name": "Upper", "translation": [0, 1, 0]},
                  {"name": "Mesh", "mesh": 0, "skin": 0}],
        "skins": [{"joints": [0, 1], "inverseBindMatrices": ibm}],
        "meshes": [{"primitives": [
            {"attributes": {"POSITION": pos, "NORMAL": nor, "TEXCOORD_0": uv, "JOINTS_0": jnt, "WEIGHTS_0": wgt}, "indices": idx[0], "material": 0},
            {"attributes": {"POSITION": pos, "NORMAL": nor, "TEXCOORD_0": uv, "JOINTS_0": jnt, "WEIGHTS_0": wgt}, "indices": idx[1], "material": 0 if image_style == "none" else 1}]}],
        "materials": [{"name": "Plain", "pbrMetallicRoughness": {"baseColorFactor": [0.5, 0.5, 0.5, 1]}}] if image_style == "none" else [
            {"name": "Skin", "pbrMetallicRoughness": {"baseColorFactor": [1, 0.9, 0.8, 1], "baseColorTexture": {"index": 0}, "metallicFactor": 0.1, "roughnessFactor": 0.7},
             "normalTexture": {"index": 1, "scale": 0.5}},
            {"name": "Armour", "pbrMetallicRoughness": {"metallicFactor": 0.9, "roughnessFactor": 0.3, "baseColorTexture": {"index": 2}},
             "emissiveFactor": [0.2, 0, 0], "alphaMode": "MASK", "alphaCutoff": 0.4, "doubleSided": True}],
        **({} if image_style == "none" else {"textures": [{"source": 0}, {"source": 1}, {"source": 2}], "images": images}),
        "accessors": accessors, "bufferViews": views, "buffers": [{"byteLength": len(blob)}],
        "animations": [{"name": "Wave", "channels": [{"sampler": 0, "target": {"node": 1, "path": "rotation"}}],
                        "samplers": [{"input": accessor("<f", [(0,), (1,)], "SCALAR", 5126, {"min": [0], "max": [1]}), "output": accessor("<4f", [(0, 0, 0, 1), (0, 0, 0.383, 0.924)], "VEC4", 5126)}]}],
    }
    gltf["buffers"][0]["byteLength"] = len(blob)
    text = json.dumps(gltf, separators=(",", ":")).encode()
    while len(text) % 4: text += b" "
    while len(blob) % 4: blob.append(0)
    glb = struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(text) + 8 + len(blob)) + struct.pack("<II", len(text), 0x4E4F534A) + text + struct.pack("<II", len(blob), 0x004E4942) + bytes(blob)
    open(os.path.join(HERE, name + ".glb"), "wb").write(glb)

os.makedirs(HERE, exist_ok=True)
build("embedded", "embedded")
build("datauri", "datauri")
build("beside", "file")
build("plain", "none")
print("Wrote", sorted(os.listdir(HERE)))
