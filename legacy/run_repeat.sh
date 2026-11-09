#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=08:00:00
#SBATCH --job-name="1D_cobalt_cbed_repeat"
#SBATCH --output=run_repeat.out
#SBATCH --error=run_repeat.err
#SBATCH --partition=short
#SBATCH --constrain=ib,cascadelake

#
# One calendar year repeated n times (10 x 1993 by default), with that year's
# JRA55-do forcing in every segment.
#   sbatch run_repeat.sh [year] [n_segments] [cbed_ic]
# Segment k restarts from RESTART_seg<k-1> if that exists, with the clock reset
# to <year>-01-01 (force_date_from_namelist); otherwise it is a cold start with
# cbed_ic (relative to INPUT/, default cbed/GofME/generic_CBED.res.nc).
# A segment whose RESTART_segNN exists is done and is skipped.
# Outputs: history/segNN/ (netCDF, logs) and RESTART_segNN/ (restarts).

set -e
YEAR="${1:-1993}"
NSEG="${2:-10}"
CBED_IC="${3:-cbed/GofME/generic_CBED.res.nc}"   # cbed initial condition for a cold start, relative to INPUT/
cd "${EXPDIR:-/home/d.sasaki/scratch/mom_experiments2/202610_cbed_1D/OM4.single_column.COBALT.station}"
source intel_long.env

FORCING=../../datasets/station_1d          # as seen from INPUT/
CBED_DEFAULT=cbed/GofME/generic_CBED.res.nc   # linked back at the end, for single-year 2004 runs
[ -e "INPUT/$CBED_IC" ] || { echo "ERROR: cbed initial condition INPUT/$CBED_IC not found" >&2; exit 1; }

# forcing of this year, the same for every segment
for v in huss prra prsn psl rlds rsds tas uas vas; do
    ( cd INPUT && ln -sfn $FORCING/${v}_*JRA55-do-1-5-0_gr_${YEAR}*.padded.nc JRA_$v.nc )
done

for (( s=1; s<=NSEG; s++ )); do
    seg=$(printf "seg%02d" $s)
    prev=$(printf "seg%02d" $((s-1)))
    if [ -d RESTART_$seg ]; then
        echo "=== $seg: done already (RESTART_$seg exists), skipped"
        continue
    fi
    echo "=== $seg ($YEAR) : $(date '+%H:%M:%S') ==="

    # initial state: previous segment's restarts if they exist, otherwise cold start from CBED_IC
    rm -f INPUT/coupler.res
    if [ ! -d RESTART_$prev ]; then
        echo "    cold start, cbed initial condition: $CBED_IC"
        ln -sfn $CBED_IC INPUT/generic_CBED.res.nc
        ifile=n
        force=''
    else
        echo "    restart from RESTART_$prev, clock reset to $YEAR-01-01"
        ( cd INPUT && ln -sfn ../RESTART_$prev/* . )
        ifile=r
        force="/current_date = /a\            force_date_from_namelist = .true.,"
    fi
    [ -e INPUT/generic_CBED.res.nc ] || { echo "ERROR: INPUT/generic_CBED.res.nc missing for $seg" >&2; exit 1; }

    # namelist of this segment
    mkdir -p history/$seg RESTART
    sed -e "s/current_date = 2004,/current_date = $YEAR,/" \
        -e "s/input_filename = 'n'/input_filename = '$ifile'/" \
        -e "s#output_directory = 'OUTPUT/'#output_directory = 'history/$seg/'#" \
        ${force:+-e "$force"} \
        input.nml_1yr > input.nml_repeat
    ln -sfn input.nml_repeat input.nml

    mpiexec -np 1 ./mom6 > history/$seg/$seg.out 2> history/$seg/$seg.err
    [ -f RESTART/generic_CBED.res.nc ] || { echo "ERROR: $seg wrote no RESTART/generic_CBED.res.nc" >&2; exit 1; }

    mv ${YEAR}0101.*.nc history/$seg/
    mv RESTART RESTART_$seg
done

# back to the single-year 2004 setup
for v in huss prra prsn psl rlds rsds tas uas vas; do
    ( cd INPUT && ln -sfn $FORCING/${v}_*JRA55-do-1-4-0_gr_2004*.padded.nc JRA_$v.nc )
done
find INPUT -maxdepth 1 -lname '../RESTART_*' -delete
ln -sfn $CBED_DEFAULT INPUT/generic_CBED.res.nc
ln -sfn input.nml_1yr input.nml
