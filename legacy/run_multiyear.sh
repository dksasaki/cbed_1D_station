#!/bin/bash
#
# Multi-year single-column run under repeat-year forcing.
#
#   usage: ./run_multiyear.sh <n_years> [executable]
#   e.g.   ./run_multiyear.sh 10
#          ./run_multiyear.sh 2 ../../builds/build/mac-m1-osx-gnu/ocean_ice/repro/MOM6SIS2
#
# The JRA55-do forcing in this experiment covers calendar year 2004 only, so a
# multi-year integration re-runs that same year repeatedly. Each segment reads
# the ocean / sea-ice / BGC state left by the previous one but resets the model
# clock back to 2004-01-01, so the forcing always lines up. This is standard
# repeat-year forcing (RYF): the ocean spins up, the atmosphere does not vary
# between years.
#
# The clock reset is done with force_date_from_namelist = .true. in
# input.nml_1yr_rst, which overrides the date in INPUT/coupler.res while still
# using the restart fields. Segment 1 is a cold start (input.nml_1yr).
#
# Because every segment carries the same model dates, output files from
# different segments would otherwise overwrite each other. Each segment's
# history and restarts are therefore moved into history/yearNN/ and
# RESTART_yearNN/ when it finishes.
#
# Run ./setup_station.sh first -- this script does not build the grid.

set -e

NYEARS="${1:-10}"
EXE="${2:-../../builds/build/mac-m1-osx-gnu/ocean_ice/repro/MOM6SIS2}"

case "$NYEARS" in
    ''|*[!0-9]*) echo "usage: $0 <n_years> [executable]" >&2; exit 1 ;;
esac

cd "$(dirname "$0")"

if [ ! -x "$EXE" ]; then
    echo "ERROR: executable not found: $EXE" >&2
    echo "       pass the path as the second argument if your build differs." >&2
    exit 1
fi
if [ ! -e INPUT/ocean_hgrid.nc ]; then
    echo "ERROR: INPUT/ocean_hgrid.nc missing -- run ./setup_station.sh first." >&2
    exit 1
fi

echo "Repeat-year forcing: $NYEARS x calendar year 2004"
echo "Executable: $EXE"
echo

for (( y=1; y<=NYEARS; y++ )); do
    tag=$(printf "year%02d" "$y")
    echo "=== segment $y / $NYEARS ($tag) : $(date '+%H:%M:%S') ==="

    # Clear restart links left by a previous segment or an earlier invocation.
    # This matters even for the cold start: the coupler reads INPUT/coupler.res
    # for the start date whenever that file exists, regardless of
    # input_filename, so a stale one silently starts the run at the wrong date
    # and it fails when the forcing runs out.
    rm -f INPUT/*.res.nc INPUT/coupler.res

    if [ "$y" -eq 1 ]; then
        ln -sfn input.nml_1yr input.nml          # cold start from climatology
    else
        ln -sfn input.nml_1yr_rst input.nml      # continue from previous state
        # Hand the previous segment's restarts to the model as initial conditions.
        prev=$(printf "RESTART_year%02d" $((y-1)))
        ( cd INPUT && ln -sf ../"$prev"/* . )
    fi

    # Clear any output left in the working directory before running, so the
    # archive step below can only ever pick up this segment's files. Without
    # this, stale history from an earlier run is silently filed under this
    # segment.
    rm -rf RESTART && mkdir -p RESTART
    find . -maxdepth 1 \( -name '2004*.nc' -o -name '2004*.nc.[0-9]*' \
        -o -name 'ocean.stats' -o -name 'ocean.stats.nc' \
        -o -name 'seaice.stats' \) -delete

    if ! mpirun -np 1 "$EXE" > "$tag.out" 2> "$tag.err"; then
        echo "ERROR: segment $y failed -- see $tag.out / $tag.err" >&2
        exit 1
    fi

    # Guard against a segment that exits 0 but produced no restart.
    if [ ! -f RESTART/MOM.res.nc ]; then
        echo "ERROR: segment $y wrote no RESTART/MOM.res.nc" >&2
        exit 1
    fi

    mkdir -p "history/$tag"
    for f in 2004*.nc 2004*.nc.[0-9]*; do
        [ -e "$f" ] && mv "$f" "history/$tag/"
    done
    for f in ocean.stats ocean.stats.nc seaice.stats; do
        [ -e "$f" ] && mv "$f" "history/$tag/"
    done
    mv "$tag.out" "$tag.err" "history/$tag/" 2>/dev/null || true

    rm -rf "RESTART_$tag" && mv RESTART "RESTART_$tag"

    tail -1 "history/$tag/ocean.stats" 2>/dev/null \
        | awk -F, '{print "    end of segment:"$8", "$9}'
done

# Leave INPUT/ without restart links, so a subsequent single-year run is not
# hijacked by the coupler.res of the last segment.
rm -f INPUT/*.res.nc INPUT/coupler.res

echo
echo "Done. $NYEARS segments complete."
echo "  history/yearNN/    per-segment diagnostics and ocean.stats"
echo "  RESTART_yearNN/    per-segment restarts (RESTART_year%02d is the final state)"
echo
echo "Note: every segment is calendar year 2004, so history files in different"
echo "      yearNN directories share the same 2004* names by design."
