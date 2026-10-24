#!/bin/bash -eu
# Package the Atheris target with the base image's compile_python_fuzzer (PyInstaller).
# script/coincide is bundled as data; the target loads it from the bundle at run time.
compile_python_fuzzer "$SRC/coincide/Tests/Fuzz/coincide_cli_fuzzer.py" \
  --add-data "$SRC/coincide/script/coincide:."
