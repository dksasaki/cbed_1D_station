#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=04:00:00
#SBATCH --job-name="1D_cobalt_cbed_years"
#SBATCH --output=run_years.out
#SBATCH --error=run_years.err
#SBATCH --partition=short
#SBATCH --constrain=ib,cascadelake

#
# Consecutive years 1993-1995 (or <first> <last>) with yearly JRA55-do forcing.
#   sbatch run_years.sh [first_year] [last_year] [cbed_ic]
# A year restarts from RESTART_<year-1> if that exists, otherwise it is a cold
# start with cbed_ic (relative to INPUT/, default cbed/GofME/generic_CBED.res.nc).
# Outputs: history/YYYY/ (netCDF, logs) and RESTART_YYYY/ (restarts).

set -e
Y0="${1:-1993}"
Y1="${2:-1995}"
CBED_IC="${3:-cbed/GofME/generic_CBED.res.nc}"   # cbed initial condition for a cold start, relative to INPUT/
cd "${EXPDIR:-/home/d.sasaki/scratch/mom_experiments2/202610_cbed_1D/OM4.single_column.COBALT.station}"
source intel_long.env

FORCING=../../datasets/station_1d          # as seen from INPUT/
CBED_DEFAULT=cbed/GofME/generic_CBED.res.nc   # linked back at the end, for single-year 2004 runs
[ -e "INPUT/$CBED_IC" ] || { echo "ERROR: cbed initial condition INPUT/$CBED_IC not found" >&2; exit 1; }

for (( y=Y0; y<=Y1; y++ )); do
    echo "=== $y : $(date '+%H:%M:%S') ==="

    # forcing of this year
    for v in huss prra prsn psl rlds rsds tas uas vas; do
        ( cd INPUT && ln -sfn $FORCING/${v}_*JRA55-do-1-5-0_gr_${y}*.padded.nc JRA_$v.nc )
    done

    # initial state: previous year's restarts if they exist, otherwise cold start from CBED_IC
    rm -f INPUT/coupler.res
    if [ ! -d RESTART_$((y-1)) ]; then
        echo "    cold start, cbed initial condition: $CBED_IC"
        ln -sfn $CBED_IC INPUT/generic_CBED.res.nc
        ifile=n
    else
        echo "    restart from RESTART_$((y-1))"
        ( cd INPUT && ln -sfn ../RESTART_$((y-1))/* . )
        ifile=r
    fi
    [ -e INPUT/generic_CBED.res.nc ] || { echo "ERROR: INPUT/generic_CBED.res.nc missing for $y" >&2; exit 1; }

    # namelist of this year
    mkdir -p history/$y RESTART
    sed -e "s/current_date = 2004,/current_date = $y,/" \
        -e "s/input_filename = 'n'/input_filename = '$ifile'/" \
        -e "s#output_directory = 'OUTPUT/'#output_directory = 'history/$y/'#" \
        input.nml_1yr > input.nml_years
    ln -sfn input.nml_years input.nml

    mpiexec -np 1 ./mom6 > history/$y/$y.out 2> history/$y/$y.err
    [ -f RESTART/generic_CBED.res.nc ] || { echo "ERROR: $y wrote no RESTART/generic_CBED.res.nc" >&2; exit 1; }

    mv ${y}0101.*.nc history/$y/
    mv RESTART RESTART_$y
done

# back to the single-year 2004 setup
for v in huss prra prsn psl rlds rsds tas uas vas; do
    ( cd INPUT && ln -sfn $FORCING/${v}_*JRA55-do-1-4-0_gr_2004*.padded.nc JRA_$v.nc )
done
find INPUT -maxdepth 1 -lname '../RESTART_*' -delete
ln -sfn $CBED_DEFAULT INPUT/generic_CBED.res.nc
ln -sfn input.nml_1yr input.nml
