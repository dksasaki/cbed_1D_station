#!/bin/bash
#
# Step 0 - link the files that are the same at every station into model/INPUT/,
#          and the executable as model/mom6.
#
# Reads   config.sh            all settings
# Writes  model/INPUT/*.nc     (links), model/mom6 (link)
#         experiment.txt       a summary of this experiment's settings
#
# The atmospheric forcing (model/INPUT/ERA5_*.nc) is linked later by run.sh,
# because it changes with the year being simulated.
#
set -e
source config.sh
mkdir -p model/INPUT

# link the ORIGINAL file: a source that is itself a link is followed to its real target
link() { ln -sf "$(readlink -f "$1")" "$2"; }

# initial conditions, the same files as 202611_nocbed (NWA25 grid, read and interpolated by the model):
# temperature and salinity (GLORYS, 2018-01-01; matches YEAR0) and all BGC tracers
link "$IC_DIR/glorys_ic_2018-01-01.nc"                        model/INPUT/
link "$IC_DIR/bgc_woa_esper_ics_1993_2023-04_update2.nc"      model/INPUT/

# vertical grid (75 layers, 2 m at the top) and the z diagnostic grid, as in 202611_nocbed
link "$IC_DIR/vgrid_75_2m.nc"                                 model/INPUT/
link "$IC_DIR/diag_dz.nc"                                     model/INPUT/

# atmospheric deposition of iron, dust and nitrogen (ESM4 1993-2014 climatologies, wet and dry)
for v in dryfe wetfe drydust wetdust drynoy wetnoy drynh4 wetnh4; do
    link "$DEPOSITION_DIR/esm4_${v}_climo_1993-2014.nc"    model/INPUT/
done

# other model inputs
link "$DATASETS/seawifs-clim-1997-2010.1440x1080.v20180328.nc" model/INPUT/
link "$DATASETS/geothermal_davies2013_v1.nc"               model/INPUT/
link "$DATASETS/diag_rho2.nc"                              model/INPUT/

# the model executable
link "$EXE" model/mom6

# every link must point to an existing file
for f in model/INPUT/*.nc model/mom6; do
    if [ ! -e "$f" ]; then
        echo "ERROR: $f points to a missing file: $(readlink "$f")" >&2
        exit 1
    fi
done

# a one-page summary of the settings, kept with the experiment
{
    echo "experiment   $(basename "$PWD")"
    echo "station      $STATION  lat $LAT  lon $LON  depth $DEPTH m"
    echo "executable   $EXE"
    echo "cbed IC      $CBED_IC"
    echo "porosity     data_table:$(grep '"por"' model/data_table)"
    echo "run          mode=$MODE  year0=$YEAR0  year1=$YEAR1  nseg=$NSEG  ic_mode=$IC_MODE"
    echo "sponge       tau=${SPONGE_TAU}d  GLORYS=$GLORYS_DIR  COBALT=$COBALT_DIR"
    echo "created      $(date '+%F %T') by 0_link_data.sh"
} > experiment.txt

echo "Step 0 done: global inputs linked into model/INPUT/, model/mom6 -> $EXE, experiment.txt written"
