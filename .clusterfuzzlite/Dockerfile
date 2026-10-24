FROM gcr.io/oss-fuzz-base/base-builder-python:latest@sha256:21f6fab17ace4dc76e1c56de91ee95d3d03da021df94b41056ba036f6c6f55e9
COPY . $SRC/coincide
WORKDIR $SRC/coincide
COPY .clusterfuzzlite/build.sh $SRC/
