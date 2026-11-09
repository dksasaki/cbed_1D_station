#!/bin/bash
#
# Set up the station experiments; the model is not run.
#   3 stations x 2 executables x 2 CBED initial states = 12 directories in <root>.
#
#   sbatch make_experiments.sh <root>     # one array task per station, in parallel
#   ./make_experiments.sh <root>          # without Slurm: all stations in turn
#
# The template is the experiment directory next to this script,
# OM4.single_column.COBALT.station/ (TEMPLATE below; override with TEMPLATE=...).
#
# For each station, its first experiment <root>/<station>_<exe1>_<ic1>/ builds
#   grid     ./setup_station.sh <station> <lat> <lon> <depth>
#   sponge   ./setup_sponge_station.sh <station> monthly   (~1 h; copied instead
#            when SPONGE_MONTHLY has a directory for the station)
#            ./setup_sponge_station.sh <station> build $SPONGE_PERIOD $SPONGE_TAU
# and the station's other experiments copy the grid and the sponge files from it.
# Every experiment then gets
#   INPUT/cbed/<station>   ./setup_cbed_station.sh <station> build <ic file>
#   mom6 -> executable, INPUT/porosity_final.nc, input.nml, diag_table, OUTPUT/,
#   run_repeat.sh and run_years.sh with its directory and station filled in,
#   and experiment.txt.
# An experiment with an experiment.txt is set up already and is left alone.
#
# Then, in each experiment:  sbatch run_repeat.sh 1993 10

# one array task per station: keep --array in step with STATION_NAMES
#SBATCH --array=0-2
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --mem=8G
#SBATCH --time=02:00:00
#SBATCH --job-name="make_experiments"
#SBATCH --output=make_experiments_%a.out
#SBATCH --error=make_experiments_%a.err
#SBATCH --partition=short

set -e

# ---- configuration ----------------------------------------------------------
# absolute, because sbatch runs a copy of this script from elsewhere
TEMPLATE="${TEMPLATE:-/home/d.sasaki/scratch/mom_experiments2/202610_cbed_1D/OM4.single_column.COBALT.station/legacy}"
DATASETS=/home/d.sasaki/scratch/mom_experiments2/202610_cbed_1D/CEFI-regional-MOM6/exps/datasets
POROSITY=/home/d.sasaki/schultz/d.sasaki/km_scale_model/mom6cobalt_25th/20240723_zstar/tasks/202603_cbed_R2py/datav4/cache/porosity_final.nc
FRE_NCTOOLS=$HOME/work/FRE-NCtools/build/bin     # only needed to build a grid
PYTHON_BIN=/projects/schultz/d.sasaki/km_scale_model/mom6cobalt_25th/20240723_zstar/tasks/202603_tasks_seabed/general_evaluation/.pixi/envs/default/bin

SPONGE_PERIOD=1993                               # 12-month cycle repeated every year (modulo)
SPONGE_TAU=90                                    # days

# station: latitude longitude depth (NEUS25 mean depth of the 0.4 degree box)
STATION_NAMES=(GofME slope midatlantic)
declare -A STATION_POS=(
    [GofME]="43.9838 -67.1743 156"
    [slope]="39.0 -68.5 3344"
    [midatlantic]="38.51 -74.36 41"
)
# sponge monthly means already computed for the same horizontal grid (optional)
declare -A SPONGE_MONTHLY=(
    [GofME]=/home/d.sasaki/scratch/mom_experiments2/202610_cbed_1D/CEFI-regional-MOM6/exps/OM4.single_column.COBALT.station/INPUT/sponge/GofME
)
EXE_NAMES=(sinksource biot_bioi)
declare -A EXES=(
    [sinksource]=/home/d.sasaki/schultz/d.sasaki/compilation/explorer/202607_CBED1.0_betav4_sinksource/builds/build/explorer-intel/ocean_ice/repro/MOM6SIS2
    [biot_bioi]=/home/d.sasaki/schultz/d.sasaki/compilation/explorer/202619_CBED1.0bv4_biot_bioi/builds/build/explorer-intel/ocean_ice/repro/MOM6SIS2
)
IC_NAMES=(mean) #median min)
declare -A ICS=(
    [mean]=/home/d.sasaki/schultz/d.sasaki/km_scale_model/mom6cobalt_25th/20240723_zstar/tasks/202603_cbed_R2py/data/cbed_results.nc
#    [median]=/home/d.sasaki/schultz/d.sasaki/km_scale_model/mom6cobalt_25th/20240723_zstar/tasks/202603_cbed_R2py/datav4/cbed_results_median.nc
#    [min]=/home/d.sasaki/schultz/d.sasaki/km_scale_model/mom6cobalt_25th/20240723_zstar/tasks/202603_cbed_R2py/datav3/cbed_results_min.nc
)
# ------------------------------------------------------------------------------

ROOT="${1:?usage: $0 <root directory for the experiments>}"
export PATH="$PYTHON_BIN:$FRE_NCTOOLS:$PATH"

for f in "$TEMPLATE" "$DATASETS/station_1d" "$POROSITY" "${EXES[@]}" "${ICS[@]}"; do
    [ -e "$f" ] || { echo "ERROR: not found: $f" >&2; exit 1; }
done
python3 -c "import netCDF4, cftime, numpy" || { echo "ERROR: python3 needs netCDF4, cftime, numpy" >&2; exit 1; }

# the INPUT/ links point to ../../datasets/station_1d, i.e. <root>/datasets;
# array tasks may get here at the same time, so an existing link is fine
mkdir -p "$ROOT"
ROOT=$(cd "$ROOT" && pwd)
[ -e "$ROOT/datasets" ] || ln -s "$DATASETS" "$ROOT/datasets" 2>/dev/null || [ -e "$ROOT/datasets" ]

if [ -n "$SLURM_ARRAY_TASK_ID" ]; then
    stations=("${STATION_NAMES[$SLURM_ARRAY_TASK_ID]}")
    [ -n "${stations[0]}" ] || { echo "ERROR: no station for array index $SLURM_ARRAY_TASK_ID" >&2; exit 1; }
else
    stations=("${STATION_NAMES[@]}")
fi

for st in "${stations[@]}"; do
    read lat lon depth <<< "${STATION_POS[$st]}"
    first="$ROOT/${st}_${EXE_NAMES[0]}_${IC_NAMES[0]}"

    for exe in "${EXE_NAMES[@]}"; do
        for ic in "${IC_NAMES[@]}"; do
            name="${st}_${exe}_${ic}"
            ed="$ROOT/$name"
            if [ -e "$ed/experiment.txt" ]; then
                echo "=== $name: already set up, left alone"
                continue
            fi
            [ ! -e "$ed" ] || { echo "ERROR: $ed exists but is incomplete -- move it away and rerun" >&2; exit 1; }
            echo "=== $name"
            cp -a "$TEMPLATE" "$ed"
            cd "$ed"

            if [ "$ed" = "$first" ]; then
                # grid and sponge of the station, built once
                command -v make_hgrid >/dev/null || { echo "ERROR: FRE-NCtools not on PATH ($FRE_NCTOOLS)" >&2; exit 1; }
                ./setup_station.sh "$st" "$lat" "$lon" "$depth"
                if [ -n "${SPONGE_MONTHLY[$st]}" ]; then
                    echo "    sponge monthly means copied from ${SPONGE_MONTHLY[$st]}"
                    mkdir -p "INPUT/sponge/$st"
                    cp -p "${SPONGE_MONTHLY[$st]}"/monthly_ts.nc "${SPONGE_MONTHLY[$st]}"/monthly_bgc.nc "INPUT/sponge/$st/"
                else
                    ./setup_sponge_station.sh "$st" monthly
                fi
                ./setup_sponge_station.sh "$st" build "$SPONGE_PERIOD" "$SPONGE_TAU"
            else
                # copied from the station's first experiment, then activated
                mkdir -p INPUT/grids "INPUT/sponge/$st"
                cp -a "$first/INPUT/grids/$st" INPUT/grids/
                cp -p "$first/INPUT/sponge/$st"/{sponge_ts.nc,sponge_bgc.nc,sponge_damping.nc,build.txt} "INPUT/sponge/$st/"
                ./setup_station.sh "$st"
                ./setup_sponge_station.sh "$st"
            fi

            ./setup_cbed_station.sh "$st" build "${ICS[$ic]}"
            ln -sfn "${EXES[$exe]}" mom6
            ln -sfn "$POROSITY" INPUT/porosity_final.nc
            ln -sfn input.nml_1yr input.nml
            ln -sfn diag_table_no_daily diag_table
            mkdir -p OUTPUT
            sed -i -e "s#^cd \"\${EXPDIR:-.*}\"#cd \"\${EXPDIR:-$ed}\"#" \
                   -e "s#cbed/GofME/generic_CBED.res.nc#cbed/$st/generic_CBED.res.nc#g" run_repeat.sh run_years.sh

            # written last: marks the experiment as set up
            cat > experiment.txt <<EOF
experiment   $name
station      $st  lat $lat  lon $lon  depth $depth m
executable   ${EXES[$exe]}
cbed IC      ${ICS[$ic]}
sponge       $(cat "INPUT/sponge/$st/build.txt")
created      $(date '+%F %T') by make_experiments.sh
EOF
            cd "$ROOT"
        done
    done
done

echo
echo "Done: ${stations[*]}. Run an experiment with:  cd $ROOT/<experiment> && sbatch run_repeat.sh 1993 10"
