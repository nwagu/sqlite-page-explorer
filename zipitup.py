import subprocess, os, shutil
from pathlib import Path

# Delete old zipped bean, copy new
basePath = Path(__file__).parent
beanPath = basePath / 'sqlite-page-explorer.com'
if beanPath.exists():
    beanPath.unlink()
shutil.copy(basePath / 'redbean-3.0.0-cosmos.com', beanPath)

# Traverse /files...
filesToZip = []  # [(relPath, skipCompress)]
filesPath = basePath / 'files'
for path, dirs, files in os.walk(filesPath): 
    for file in files:
        fullPath = Path(path, file)
        zipPath = fullPath.relative_to(filesPath).as_posix()
        skipCompress = fullPath.suffix in ('.png', '.woff', 'woff2', '.ttf', '.otf')
        filesToZip.append((zipPath, skipCompress))
        
# Zip all into the binary
for path, skipCompress in filesToZip:
    args = ['zip']
    if skipCompress:
        args.append('-0')
    args.append(beanPath)
    args.append(path)
    subprocess.run(args, shell=True, cwd=filesPath)