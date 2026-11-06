#!/bin/bash
#
# Step 0 - link the files that are the same at every station into model/INPUT/,
#          and the executable as model/mom6.
#
# Reads   config.sh            all settings
# Writes  model/INPUT/*.nc     (links), model/mom6 (link)
#         experiment.txt       a summary of this experiment's settings
#
# The atmospheric forcing (model/INPUT/JRA_*.nc) is linked later by run.sh,
# because it changes with the year being simulated.
#
set -e
source config.sh
mkdir -p model/INPUT

# initial conditions: temperature and salinity (WOA13, monthly)
ln -sf "$DATASETS/woa13_decav_ptemp_monthly_fulldepth_01.nc" model/INPUT/
ln -sf "$DATASETS/woa13_decav_s_monthly_fulldepth_01.nc"     model/INPUT/

# initial conditions: nutrients and O2 (WOA13, annual), DIC and Alk (GLODAPv2), all other COBALT tracers
ln -sf "$DATASETS/woa13_all_n_annual_01.nc"                  model/INPUT/
ln -sf "$DATASETS/woa13_all_o_annual_01.nc"                  model/INPUT/
ln -sf "$DATASETS/woa13_all_p_annual_01.nc"                  model/INPUT/
ln -sf "$DATASETS/woa13_all_i_annual_01.nc"                  model/INPUT/
ln -sf "$DATASETS/GLODAPv2.2016b.oi-filled.20180322.nc"      model/INPUT/
ln -sf "$DATASETS/cobaltv3_tracer_source.nc"                 model/INPUT/

# atmospheric deposition of iron, dust and nitrogen (pre-industrial climatologies)
ln -sf "$DATASETS/Soluble_Fe_Flux_PI.nc"                     model/INPUT/
ln -sf "$DATASETS/Mineral_Fe_Flux_PI.nc"                     model/INPUT/
ln -sf "$DATASETS/depflux_total.mean.1860.nc"                model/INPUT/

# other model inputs
ln -sf "$DATASETS/seawifs-clim-1997-2010.1440x1080.v20180328.nc" model/INPUT/
ln -sf "$DATASETS/geothermal_davies2013_v1.nc"               model/INPUT/
ln -sf "$DATASETS/diag_rho2.nc"                              model/INPUT/

# CBED porosity (read through data_table)
ln -sf "$POROSITY" model/INPUT/porosity_final.nc

# the model executable
ln -sf "$EXE" model/mom6

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
    echo "porosity     $POROSITY"
    echo "run          mode=$MODE  year0=$YEAR0  year1=$YEAR1  nseg=$NSEG"
    echo "sponge       tau=${SPONGE_TAU}d  GLORYS=$GLORYS_DIR  COBALT=$COBALT_DIR"
    echo "created      $(date '+%F %T') by 0_link_data.sh"
} > experiment.txt

echo "Step 0 done: global inputs linked into model/INPUT/, model/mom6 -> $EXE, experiment.txt written"
