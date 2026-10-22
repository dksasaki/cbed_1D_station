#!/bin/bash
#
# Select the station this experiment runs at, building its grid if needed.
#
#   ./setup_station.sh                                 list grids already built
#   ./setup_station.sh <name>                          activate an existing grid
#   ./setup_station.sh <name> <lat> <lon> [depth_m]    build a grid, then activate it
#
#   e.g.  ./setup_station.sh BATS  31.6667  -64.1667          # first time
#         ./setup_station.sh HOT   22.75   -158.0     4800
#         ./setup_station.sh BATS                             # switch back later
#         SPONGE_DAYS=90 ./setup_station.sh BATS              # 90-day restoring
#
# Grids are kept per station under INPUT/grids/<name>/ and are never deleted
# except by rebuilding that same station, so a set of stations can be built
# once and then switched between freely. Only the build path needs FRE-NCtools
# on PATH:
#   export PATH="$HOME/work/FRE-NCtools/build/bin:$PATH"
#
# Everything else in this experiment is global, so once a grid is active the
# case runs at that location with no further changes.

set -e

expdir="$(cd "$(dirname "$0")" && pwd)"
cd "$expdir"

# Files make_coupler_mosaic produces that the model reads.
GRID_FILES="ocean_hgrid.nc ocean_topog.nc ocean_mosaic.nc atmos_mosaic.nc \
land_mosaic.nc land_mask.nc ocean_mask.nc grid_spec.nc \
atmos_mosaic_tile1Xocean_mosaic_tile1.nc land_mosaic_tile1Xocean_mosaic_tile1.nc"

# Per-station 3-D restoring inputs written by make_sponge.py.
SPONGE_FILES="sponge_damping.nc sponge_state_woa13.nc sponge_bgc.nc"

list_grids() {
    if [ -d INPUT/grids ] && [ -n "$(ls -A INPUT/grids 2>/dev/null)" ]; then
        echo "Grids already built (activate with: $0 <name>):"
        for d in INPUT/grids/*/; do
            name=$(basename "$d")
            # Report the centre of the box straight from the grid file.
            centre=$(python3 - "$d/ocean_hgrid.nc" <<'PY' 2>/dev/null || true
import sys
try:
    import netCDF4, numpy as np
    d = netCDF4.Dataset(sys.argv[1])
    x = np.asarray(d.variables['x'][:]); y = np.asarray(d.variables['y'][:])
    print(f"lat {y.mean():7.3f}, lon {x.mean():8.3f}")
except Exception:
    pass
PY
)
            if [ -n "$centre" ]; then
                printf "  %-16s %s\n" "$name" "$centre"
            else
                printf "  %-16s\n" "$name"
            fi
        done
    else
        echo "No grids built yet."
        echo "Build one with: $0 <station_name> <latitude> <longitude> [bottom_depth_m]"
    fi
}

usage() {
    echo "usage: $0                                        list grids already built" >&2
    echo "       $0 <name>                                 activate an existing grid" >&2
    echo "       $0 <name> <latitude> <longitude> [depth]  build a grid, then activate" >&2
}

case "$#" in
    0) list_grids; exit 0 ;;
    1) mode=activate ;;
    3|4) mode=build ;;
    *) usage; exit 1 ;;
esac

station="$1"
griddir="INPUT/grids/$station"

if [ "$mode" = build ]; then
    lat="$2"; lon="$3"; depth="${4:-4000}"

    for tool in make_hgrid make_solo_mosaic make_topog make_coupler_mosaic; do
        command -v "$tool" >/dev/null 2>&1 || {
            echo "ERROR: $tool not found on PATH." >&2
            echo "       export PATH=\"\$HOME/work/FRE-NCtools/build/bin:\$PATH\"" >&2
            echo "       (only needed to build a grid; $0 <name> reuses one)" >&2
            exit 1
        }
    done

    # 0.4 deg box centred on the station, 4x4 ocean cells (8x8 supergrid),
    # matching the geometry of the CI single-column case.
    xmin=$(awk -v v="$lon" 'BEGIN{printf "%.4f", v-0.2}')
    xmax=$(awk -v v="$lon" 'BEGIN{printf "%.4f", v+0.2}')
    ymin=$(awk -v v="$lat" 'BEGIN{printf "%.4f", v-0.2}')
    ymax=$(awk -v v="$lat" 'BEGIN{printf "%.4f", v+0.2}')

    echo "Building grid for $station at (${lat}, ${lon}), bottom depth ${depth} m"
    rm -rf "$griddir"
    mkdir -p "$griddir"
    (
        cd "$griddir"
        make_hgrid --grid_type regular_lonlat_grid \
                   --nxbnd 2 --nybnd 2 \
                   --xbnd "$xmin,$xmax" --ybnd "$ymin,$ymax" \
                   --nlon 8 --nlat 8 \
                   --grid_name ocean_hgrid > make_hgrid.log 2>&1

        for m in ocean atmos land; do
            make_solo_mosaic --num_tiles 1 --dir ./ \
                             --mosaic_name ${m}_mosaic --tile_file ocean_hgrid.nc \
                             > make_solo_mosaic_${m}.log 2>&1
        done

        make_topog --mosaic ocean_mosaic.nc --topog_type rectangular_basin \
                   --bottom_depth "$depth" --output ocean_topog.nc \
                   > make_topog.log 2>&1

        make_coupler_mosaic --atmos_mosaic atmos_mosaic.nc \
                            --land_mosaic land_mosaic.nc \
                            --ocean_mosaic ocean_mosaic.nc \
                            --ocean_topog ocean_topog.nc \
                            --mosaic_name grid_spec --check --verbose \
                            > make_coupler_mosaic.log 2>&1
    )
else
    if [ ! -d "$griddir" ]; then
        echo "ERROR: no grid for '$station' under INPUT/grids/." >&2
        echo "       Build it first:" >&2
        echo "         $0 $station <latitude> <longitude> [bottom_depth_m]" >&2
        echo >&2
        list_grids >&2
        exit 1
    fi
    # A grid directory can exist but be incomplete if an earlier build failed.
    for f in $GRID_FILES; do
        if [ ! -e "$griddir/$f" ]; then
            echo "ERROR: $griddir is incomplete (missing $f)." >&2
            echo "       Rebuild it: $0 $station <latitude> <longitude> [depth]" >&2
            exit 1
        fi
    done
    echo "Activating existing grid for $station"
fi

# 3-D restoring inputs (see make_sponge.py). They depend only on the grid,
# so build them once per station; a rebuilt grid gets fresh ones.
# SPONGE_DAYS=<days> rebuilds them with that restoring timescale (default 90).
missing=""
for f in $SPONGE_FILES; do [ -e "$griddir/$f" ] || missing=yes; done
if [ -n "$SPONGE_DAYS" ] || [ -n "$missing" ]; then
    python3 make_sponge.py "$griddir" ${SPONGE_DAYS:+"$SPONGE_DAYS"}
fi

# Point INPUT/ at the chosen station, replacing whatever was active before.
( cd INPUT && for f in $GRID_FILES $SPONGE_FILES; do ln -sfn "grids/$station/$f" "$f"; done
  ln -sfn ocean_topog.nc topog.nc )

echo "Station '$station' is now active in INPUT/."
tau=$(ncdump -h "$griddir/sponge_damping.nc" 2>/dev/null \
      | sed -n 's/.*restoring_timescale_days = \([0-9.]*\).*/\1/p' | awk '{printf "%g", $1}')
echo "3-D restoring timescale: ${tau:-unknown} days" \
     "(change with: SPONGE_DAYS=<days> $0 $station)"

if [ "$mode" = build ]; then
    echo "Tiling check from make_coupler_mosaic:"
    grep -E "tiling error|ocean fraction|land  fraction" \
        "$griddir/make_coupler_mosaic.log" || true
fi
