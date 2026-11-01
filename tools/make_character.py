#!/usr/bin/env python3
"""Generates the sample animated character: a prefab of bones with low-poly body parts,
and idle / walk / run / jump clips.

Usage: make_character.py <asset folder>   (writes Prefabs/character.tprefab and Animations/*.tanim)

Conventions: the character faces +Z and stands with its feet at the origin. Rotation X swings
a limb: negative forwards, positive backwards. Left is -X.
"""
import math, os, sys

SKIN, SHIRT, PANTS, SHOES, HAIR = (233, 190, 150), (64, 132, 200), (58, 66, 92), (40, 40, 46), (86, 58, 38)

class Prefab:
    def __init__(self):
        self.lines, self.next_id = [], 1

    def obj(self, name, parent, pos, scale=(1, 1, 1)):
        oid = self.next_id; self.next_id += 1
        self.lines.append(f'object {oid} parent {parent} active 1 name "{name}"')
        self.lines.append('transform %g %g %g 0 0 0 1 %g %g %g' % (*pos, *scale))
        return oid

    def component(self, type_name, fields):
        self.lines.append(f'component {type_name} enabled 1')
        for key, value in fields:
            self.lines.append(f'field {key} {value}')

    def box(self, parent, center, size, color):
        self.obj('mesh', parent, center, size)
        self.component('Tallow.MeshRenderer', [('mesh', '"builtin:cube"'),
            ('color', '%g %g %g 1' % tuple(round(c / 255, 4) for c in color)), ('roughness', '0.9'), ('flatShading', '1')])

def build_prefab(path):
    p = Prefab()
    root = p.obj('Character', 0, (0, 0, 0))
    clips = ';'.join('Animations/%s.tanim' % n for n in ('idle', 'walk', 'run', 'jump'))
    p.component('Tallow.Animator', [('clips', '"%s"' % clips), ('defaultClip', '"Idle"'), ('speed', '1')])
    hips = p.obj('Hips', root, (0, 0.95, 0))
    p.box(hips, (0, 0.05, 0), (0.34, 0.2, 0.2), PANTS)
    chest = p.obj('Chest', hips, (0, 0.18, 0))
    p.box(chest, (0, 0.21, 0), (0.42, 0.42, 0.24), SHIRT)
    head = p.obj('Head', chest, (0, 0.46, 0))
    p.box(head, (0, 0.16, 0), (0.26, 0.28, 0.26), SKIN)
    p.box(head, (0, 0.31, -0.02), (0.28, 0.08, 0.3), HAIR)
    p.box(head, (0, 0.2, -0.13), (0.28, 0.2, 0.06), HAIR)
    for side, x in (('L', -1), ('R', 1)):
        upper = p.obj('UpperArm.' + side, chest, (x * 0.27, 0.38, 0))
        p.box(upper, (0, -0.15, 0), (0.12, 0.3, 0.12), SHIRT)
        lower = p.obj('LowerArm.' + side, upper, (0, -0.3, 0))
        p.box(lower, (0, -0.13, 0), (0.1, 0.26, 0.1), SKIN)
        p.box(lower, (0, -0.3, 0), (0.11, 0.1, 0.11), SKIN)
        thigh = p.obj('UpperLeg.' + side, hips, (x * 0.1, -0.03, 0))
        p.box(thigh, (0, -0.22, 0), (0.15, 0.44, 0.15), PANTS)
        shin = p.obj('LowerLeg.' + side, thigh, (0, -0.44, 0))
        p.box(shin, (0, -0.2, 0), (0.13, 0.4, 0.13), PANTS)
        p.box(shin, (0, -0.42, 0.05), (0.14, 0.08, 0.25), SHOES)
    with open(path, 'w') as f:
        f.write('\n'.join(p.lines) + '\n')

def write_clip(path, name, duration, loop, pose, samples=12):
    """pose(phase 0..1) returns {bone: (px, py, pz, ex, ey, ez)}."""
    tracks = {}
    for i in range(samples + 1):
        phase = i / samples
        for bone, values in pose(phase).items():
            tracks.setdefault(bone, []).append((phase * duration, values))
    with open(path, 'w') as f:
        f.write(f'clip {name} duration {duration} loop {1 if loop else 0}\n')
        for bone, keys in tracks.items():
            f.write(f'track {bone}\n')
            for time, v in keys:
                f.write('key %.4f %.4f %.4f %.4f %.3f %.3f %.3f\n' % (time, *v))

def idle(phase):
    s = math.sin(phase * math.tau)
    return {
        'Chest': (0, 0.004 * s, 0, 1.5 * s, 0, 0),
        'Head': (0, 0, 0, -1.0 * s, 4 * math.sin(phase * math.tau * 0.5), 0),
        'UpperArm.L': (0, 0, 0, 2 * s, 0, 4 + 1.5 * s), 'UpperArm.R': (0, 0, 0, 2 * s, 0, -4 - 1.5 * s),
        'LowerArm.L': (0, 0, 0, -8, 0, 0), 'LowerArm.R': (0, 0, 0, -8, 0, 0),
    }

def stride(swing, knee, arm, elbow, lean, bob):
    def pose(phase):
        s = math.sin(phase * math.tau)
        c = math.cos(phase * math.tau)
        def leg(v, cv):
            # thigh swings; the knee folds while that leg travels forwards
            return (0, 0, 0, -swing * v, 0, 0), (0, 0, 0, knee * max(0.0, cv) + 6, 0, 0)
        l_thigh, l_shin = leg(s, c)
        r_thigh, r_shin = leg(-s, -c)
        return {
            'Hips': (0, -bob * abs(c), 0, lean * 0.4, 5 * s, 0),
            'Chest': (0, 0, 0, lean, -8 * s, 0),
            'Head': (0, 0, 0, -lean * 0.6, 3 * s, 0),
            'UpperLeg.L': l_thigh, 'LowerLeg.L': l_shin, 'UpperLeg.R': r_thigh, 'LowerLeg.R': r_shin,
            # arms swing opposite to the legs
            'UpperArm.L': (0, 0, 0, arm * s, 0, 5), 'UpperArm.R': (0, 0, 0, -arm * s, 0, -5),
            'LowerArm.L': (0, 0, 0, -elbow, 0, 0), 'LowerArm.R': (0, 0, 0, -elbow, 0, 0),
        }
    return pose

def jump(phase):
    k = min(1.0, phase * 3)   # reach the airborne pose quickly, then hold it
    return {
        'Hips': (0, 0, 0, 6 * k, 0, 0), 'Chest': (0, 0, 0, -6 * k, 0, 0),
        'UpperLeg.L': (0, 0, 0, -38 * k, 0, 0), 'LowerLeg.L': (0, 0, 0, 62 * k, 0, 0),
        'UpperLeg.R': (0, 0, 0, -14 * k, 0, 0), 'LowerLeg.R': (0, 0, 0, 34 * k, 0, 0),
        'UpperArm.L': (0, 0, 0, -20 * k, 0, 55 * k), 'UpperArm.R': (0, 0, 0, -20 * k, 0, -55 * k),
        'LowerArm.L': (0, 0, 0, -25 * k, 0, 0), 'LowerArm.R': (0, 0, 0, -25 * k, 0, 0),
    }

if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else '.'
    os.makedirs(os.path.join(out, 'Prefabs'), exist_ok=True)
    os.makedirs(os.path.join(out, 'Animations'), exist_ok=True)
    build_prefab(os.path.join(out, 'Prefabs', 'character.tprefab'))
    anim = os.path.join(out, 'Animations')
    write_clip(os.path.join(anim, 'idle.tanim'), 'Idle', 2.4, True, idle)
    write_clip(os.path.join(anim, 'walk.tanim'), 'Walk', 0.9, True, stride(28, 45, 24, 12, 3, 0.025))
    write_clip(os.path.join(anim, 'run.tanim'), 'Run', 0.6, True, stride(46, 80, 44, 75, 10, 0.05))
    write_clip(os.path.join(anim, 'jump.tanim'), 'Jump', 0.5, False, jump, samples=6)
    print('character prefab and 4 clips written to', out)
