#!/bin/bash
#
# Select the CBED initial state for the station this experiment runs at,
# subsampling it from a regional CBED restart if needed.
#
#   ./setup_cbed_station.sh                              list CBED states already built
#   ./setup_cbed_station.sh <name>                       activate an existing CBED state
#   ./setup_cbed_station.sh <name> build [regional.nc]   build from the station grid, then activate
#
#   e.g.  ./setup_cbed_station.sh GofME build            # first time, default source
#         ./setup_cbed_station.sh GofME build /path/to/cbed_results_median.nc
#         ./setup_cbed_station.sh GofME                  # switch back later
#
# The station grid must already exist (./setup_station.sh <name> <lat> <lon>).
# For every ocean cell of INPUT/grids/<name>/ocean_hgrid.nc, the nearest wet
# column of the regional restart is copied, so the result has the same NI x NJ
# shape as the model domain. FMS2 read_restart does no horizontal
# interpolation: a regional-size file would be read at indices 1..NI, 1..NJ
# (the SW corner of the regional grid), not at the station.
#
# CBED states are kept per station under INPUT/cbed/<name>/ and are never
# deleted except by rebuilding that same station. Activation points
# INPUT/generic_CBED.res.nc at the chosen one. Only needed for a cold start:
# run_multiyear.sh relinks INPUT/ to the previous segment's RESTART/ afterwards.

set -e

expdir="$(cd "$(dirname "$0")" && pwd)"
cd "$expdir"

# Regional CBED restart used when no source is given on the command line.
DEFAULT_SRC="INPUT/cbed_results_median.nc"
CBED_FILE="generic_CBED.res.nc"

list_cbed() {
    if [ -d INPUT/cbed ] && [ -n "$(ls -A INPUT/cbed 2>/dev/null)" ]; then
        echo "CBED states already built (activate with: $0 <name>):"
        for d in INPUT/cbed/*/; do
            name=$(basename "$d")
            src=$(cat "$d/source.txt" 2>/dev/null || true)
            printf "  %-16s %s\n" "$name" "$src"
        done
    else
        echo "No CBED states built yet."
        echo "Build one with: $0 <station_name> build [regional_restart.nc]"
    fi
    active=$(readlink INPUT/$CBED_FILE 2>/dev/null || true)
    [ -n "$active" ] && echo "Active: INPUT/$CBED_FILE -> $active"
    return 0
}

usage() {
    echo "usage: $0                                      list CBED states already built" >&2
    echo "       $0 <name>                               activate an existing CBED state" >&2
    echo "       $0 <name> build [regional_restart.nc]   build from the station grid, then activate" >&2
}

case "$#" in
    0) list_cbed; exit 0 ;;
    1) mode=activate ;;
    2|3) [ "$2" = build ] || { usage; exit 1; }; mode=build ;;
    *) usage; exit 1 ;;
esac

station="$1"
cbeddir="INPUT/cbed/$station"

if [ "$mode" = build ]; then
    src="${3:-$DEFAULT_SRC}"
    hgrid="INPUT/grids/$station/ocean_hgrid.nc"

    if [ ! -e "$hgrid" ]; then
        echo "ERROR: no station grid $hgrid." >&2
        echo "       Build it first: ./setup_station.sh $station <latitude> <longitude> [depth]" >&2
        exit 1
    fi
    if [ ! -e "$src" ]; then
        echo "ERROR: regional CBED restart '$src' not found." >&2
        exit 1
    fi
    # Refuse a source that is itself a station subsample (e.g. the active link).
    if [ "$(readlink -f "$src")" = "$(readlink -f "INPUT/$CBED_FILE")" ] && \
       readlink "INPUT/$CBED_FILE" | grep -q '^cbed/'; then
        echo "ERROR: '$src' is the active station CBED state, not a regional restart." >&2
        exit 1
    fi

    echo "Building CBED state for $station from $src"
    rm -rf "$cbeddir"
    mkdir -p "$cbeddir"

    python3 -I - "$hgrid" "$src" "$cbeddir/$CBED_FILE" <<'PY' | tee "$cbeddir/build.log"
import sys
import numpy as np
import netCDF4

hgrid, src, out = sys.argv[1:4]

# Cell centres of the station grid (odd points of the supergrid).
g = netCDF4.Dataset(hgrid)
lon = np.asarray(g.variables['x'][1::2, 1::2])
lat = np.asarray(g.variables['y'][1::2, 1::2])
g.close()
nj, ni = lon.shape

r = netCDF4.Dataset(src)
r.set_auto_mask(False)
rx = np.asarray(r.variables['x'][:])
ry = np.asarray(r.variables['y'][:])
zdim = [d for d in r.variables['cbed_o2'].dimensions if d not in ('x', 'y')][0]
nk = r.dimensions[zdim].size

# Wet columns: finite, positive organic matter at the top layer (land is 0 / NaN).
om1_top = np.asarray(r.variables['cbed_om1'][0, :, :], dtype='f8')
wet = np.isfinite(om1_top) & (om1_top > 0)
if 'porosity' in r.variables:
    por = np.asarray(r.variables['porosity'][:], dtype='f8')
    wet &= np.isfinite(por) & (por > 0)
if not wet.any():
    sys.exit("ERROR: no wet columns found in the regional restart")

RX, RY = np.meshgrid(rx, ry)
wj, wi = np.nonzero(wet)
coslat = np.cos(np.deg2rad(lat.mean()))

pick = np.zeros((nj, ni, 2), dtype=int)
print(f"station grid {ni} x {nj}, regional grid {rx.size} x {ry.size}, {nk} sediment layers")
for j in range(nj):
    for i in range(ni):
        d2 = ((RX[wj, wi] - lon[j, i]) * coslat) ** 2 + (RY[wj, wi] - lat[j, i]) ** 2
        k = int(np.argmin(d2))
        pick[j, i] = wj[k], wi[k]
        print(f"  cell ({i+1},{j+1}) {lat[j,i]:8.3f}N {lon[j,i]:9.3f}E <- regional "
              f"(i={wi[k]}, j={wj[k]}) {ry[wj[k]]:8.3f}N {rx[wi[k]]:9.3f}E, "
              f"{np.sqrt(d2[k]) * 111.0:5.1f} km")

def copy_var(var, name, dims):
    """Create name in the output with the dtype, _FillValue and attributes of var."""
    fill = var.getncattr('_FillValue') if '_FillValue' in var.ncattrs() else None
    v = o.createVariable(name, var.dtype, dims, fill_value=fill)
    v.setncatts({k: var.getncattr(k) for k in var.ncattrs() if k != '_FillValue'})
    v.set_auto_mask(False)
    return v

# Same format as the regional source and the model-written RESTART file.
o = netCDF4.Dataset(out, 'w', format='NETCDF3_64BIT_OFFSET')
o.setncatts({k: r.getncattr(k) for k in r.ncattrs()})
o.createDimension('x', ni)
o.createDimension('y', nj)
o.createDimension('lev', nk)   # generic_CBED.F90 registers the layer axis as 'lev'

copy_var(r.variables['x'], 'x', ('x',))[:] = lon[0, :]
copy_var(r.variables['y'], 'y', ('y',))[:] = lat[:, 0]
if zdim in r.variables:
    copy_var(r.variables[zdim], 'lev', ('lev',))[:] = np.asarray(r.variables[zdim][:])

jj, ii = pick[..., 0], pick[..., 1]
for name, var in r.variables.items():
    if name in ('x', 'y', zdim, 'porosity'):
        continue
    a = np.asarray(var[:])
    if var.dimensions == (zdim, 'y', 'x'):
        a, dims = a[:, jj, ii], ('lev', 'y', 'x')
    elif var.dimensions == ('y', 'x'):
        a, dims = a[jj, ii], ('y', 'x')
    else:
        continue
    bad = ~np.isfinite(a)
    if bad.any():
        print(f"  WARNING: {name} has {int(bad.sum())} non-finite values, set to 0")
        a = np.where(bad, 0, a)
    copy_var(var, name, dims)[:] = a
o.source = src
o.history = "subsampled to station grid by setup_cbed_station.sh"
o.close()
r.close()
print(f"wrote {out}")
PY
    readlink -f "$src" > "$cbeddir/source.txt"
else
    if [ ! -e "$cbeddir/$CBED_FILE" ]; then
        echo "ERROR: no CBED state for '$station' under INPUT/cbed/." >&2
        echo "       Build it first: $0 $station build [regional_restart.nc]" >&2
        echo >&2
        list_cbed >&2
        exit 1
    fi
    echo "Activating existing CBED state for $station"
fi

# Point the restart CBED reads at the chosen station, replacing whatever was active.
( cd INPUT && ln -sfn "cbed/$station/$CBED_FILE" "$CBED_FILE" )

echo "CBED state '$station' is now active: INPUT/$CBED_FILE -> cbed/$station/$CBED_FILE"
