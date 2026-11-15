#!/usr/bin/env python3
"""Builds and runs Tests/TextEdit/editing_checks.cpp: the code editor's editing behaviour, headless."""
import os
import shutil
import subprocess
import sys
import tempfile

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
imgui = os.path.join(root, 'third_party', 'cimgui', 'imgui')
textedit = os.path.join(root, 'third_party', 'TextEdit')
compiler = os.environ.get('CXX') or shutil.which('g++') or shutil.which('clang++')
if not compiler:
    sys.exit('test_textedit: no C++ compiler (set CXX)')
with tempfile.TemporaryDirectory(prefix='tallow-textedit-') as folder:
    program = os.path.join(folder, 'editing_checks')
    sources = [os.path.join(root, 'Tests', 'TextEdit', 'editing_checks.cpp'),
               os.path.join(textedit, 'TextEditor.cpp'), os.path.join(textedit, 'TextDiff.cpp')]
    sources += [os.path.join(imgui, name) for name in ('imgui.cpp', 'imgui_draw.cpp', 'imgui_tables.cpp', 'imgui_widgets.cpp')]
    subprocess.check_call([compiler, '-std=c++20', '-O1', '-I' + imgui, '-I' + textedit, *sources, '-o', program])
    sys.exit(subprocess.call([program]))
