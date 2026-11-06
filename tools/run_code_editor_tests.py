#!/usr/bin/env python3
"""Compile and run the native document regressions without a window or BeefBuild (Linux/macOS)."""
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parent.parent
    imgui = root / 'third_party/cimgui/imgui'
    editor = root / 'third_party/TextEdit'
    sources = [root / 'native/tests/code_document_test.cpp', editor / 'TextEditor.cpp',
               editor / 'extras/TrieAutoComplete.cpp']
    sources += [imgui / name for name in ['imgui.cpp', 'imgui_draw.cpp', 'imgui_tables.cpp', 'imgui_widgets.cpp']]
    with tempfile.TemporaryDirectory(prefix='tallow-code-check-') as work:
        binary = Path(work) / 'code-document-test'
        subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++20', '-O0', '-g',
                        '-I' + str(imgui), '-I' + str(editor), *map(str, sources), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    main()
