#!/usr/bin/env python3
"""Build and run socket-independent snapshot delivery regressions against an engine package."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import tomllib
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from build_player import WINDOWS_NATIVE_LIBS, WINDOWS_SYSTEM_LIBS, WEB_NATIVE_LIBS

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--engine',type=Path,required=True)
a=p.parse_args();engine=a.engine.resolve();source=Path(__file__).resolve().parents[1]
windows=os.name=='nt';platform='Win64' if windows else 'Linux64';name='NetworkBandwidthTests'
with tempfile.TemporaryDirectory(prefix='network-bandwidth-tests-') as folder:
    root=Path(folder);shutil.copytree(source/'Tests/NetworkBandwidth/src',root/'src')
    q=json.dumps
    (root/'BeefSpace.toml').write_text('FileVersion = 1\nProjects = {'+name+' = {Path = "."}, Tallow = {Path = '+q(str(engine/'Engine').replace('\\','/'))+'}}\n[Workspace]\nStartupProject = '+q(name)+'\n'+('[Configs.Release.Win64]\nToolset = "LLVM"\n' if windows else ''))
    if windows:
        links=' '.join(q(str(engine/'build/native-win'/lib)) for lib in WINDOWS_NATIVE_LIBS)+' '+' '.join(lib+'.lib' for lib in WINDOWS_SYSTEM_LIBS)
    else:
        links='-Wl,--start-group '+' '.join(str(engine/'build/native'/lib) for lib in WEB_NATIVE_LIBS)+' -Wl,--end-group -lstdc++ -lm -ldl -lpthread -lGL -lX11'
    (root/'BeefProj.toml').write_text('FileVersion = 1\nDependencies = {corlib = "*", Tallow = "*"}\n[Project]\nName = '+q(name)+'\nTargetType = "BeefConsoleApplication"\nStartupObject = '+q(name+'.Program')+'\n[Configs.Release.'+platform+']\nCLibType = '+q('Static' if windows else 'Dynamic')+'\nOtherLinkFlags = '+q('$(LinkFlags) '+links)+'\n')
    subprocess.run([os.environ.get('BEEFBUILD','BeefBuild'),'-workspace='+str(root),'-config=Release','-verbosity=minimal'],check=True)
    subprocess.run([str(root/'build'/('Release_'+platform)/name/(name+('.exe' if windows else '')))],check=True)
