# =============================================================================
# config.sh - the settings of this experiment.
#
# Edit this file, then follow the steps in README.md.
# It is read by every step (0_link_data.sh ... run.sh).
# Run "source config.sh" once in your shell so the tools below are on PATH.
# =============================================================================

# --- station -----------------------------------------------------------------
STATION=GofME              # a name, for messages only
LAT=43.9838                # centre of the 0.4 degree box [degrees north]
LON=-67.1743               # centre of the 0.4 degree box [degrees east]
DEPTH=156                  # flat bottom [m]

# --- model -------------------------------------------------------------------
# the MOM6SIS2 executable (sinksource or biot_bioi build)
EXE=/home/d.sasaki/schultz/d.sasaki/compilation/explorer/202607_CBED1.0_betav4_sinksource/builds/build/explorer-intel/ocean_ice/repro/MOM6SIS2
# regional CBED solution: step 2 copies its nearest wet column into each station cell
CBED_IC=/home/d.sasaki/schultz/d.sasaki/km_scale_model/mom6cobalt_25th/20240723_zstar/tasks/202603_cbed_R2py/data/cbed_results.nc
# CBED porosity, read by the model through data_table
POROSITY=/home/d.sasaki/schultz/d.sasaki/km_scale_model/mom6cobalt_25th/20240723_zstar/tasks/202603_cbed_R2py/datav4/cache/porosity_final.nc

# --- run ---------------------------------------------------------------------
MODE=repeat                # repeat: YEAR0 repeated NSEG times | sequential: years YEAR0..YEAR1
YEAR0=1993
YEAR1=1993                 # sequential mode only
NSEG=10                    # repeat mode only
SEGS_PER_JOB=10            # segments per Slurm job (~35-45 min each, 8 h limit); then run.sh submits the next job

# --- nudging -----------------------------------------------------------------
SPONGE_TAU=90              # nudging timescale [days], the same for every variable

# --- data --------------------------------------------------------------------
DATASETS=/scratch/d.sasaki/mom_experiments2/202610_cbed_1D/CEFI-regional-MOM6/exps/datasets/station_1d
GLORYS_DIR=/home/d.sasaki/schultz/data/glorys/nwa25_regional/monthly_average
COBALT_DIR=/home/d.sasaki/scratch/temp/202609_delete/outputs_raw/iteration1    # NEUS25 COBALT, 1993 only

# --- tools -------------------------------------------------------------------
# the repository clone: the folder with pixi.toml, where "pixi install" and
# "pixi run install-fre-nctools" were run (see README). The default works for
# station_1d_simple inside the repo; for a copy elsewhere, put the clone's path here.
PIXI_ROOT=$(dirname "$PWD")

export PATH="$PIXI_ROOT/.pixi/envs/default/bin:$PIXI_ROOT/opt/fre-nctools/bin:$PATH"
