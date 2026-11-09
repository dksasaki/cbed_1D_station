#!/bin/bash
#
# Builds FRE-NCtools (make_hgrid, make_solo_mosaic, make_topog,
# make_coupler_mosaic, ...) with the compilers and netCDF of the pixi
# environment, and installs them in opt/fre-nctools/bin.
#
# Run it once, through pixi (so CC, FC, nc-config, nf-config are set):
#
#   pixi run install-fre-nctools
#
set -e
cd "$PIXI_PROJECT_ROOT"

# 1. the source code
mkdir -p opt
if [ ! -d opt/FRE-NCtools-src ]; then
    git clone https://github.com/NOAA-GFDL/FRE-NCtools opt/FRE-NCtools-src
fi
cd opt/FRE-NCtools-src

# 2. configure
autoreconf -i
mkdir -p build
cd build
../configure --prefix="$PIXI_PROJECT_ROOT/opt/fre-nctools"

# 3. build and install
make -j 4
make install

echo "FRE-NCtools installed in $PIXI_PROJECT_ROOT/opt/fre-nctools/bin"
