# =============================================================================
# config.sh - the settings of this experiment.
#
# Edit this file, then follow the steps in README.md.
# It is read by every step (0_link_data.sh ... run.sh).
# Run "source config.sh" once in your shell so the tools below are on PATH.
# =============================================================================

# --- station -----------------------------------------------------------------
STATION=GofME              # a name, for messages only
# true 1D: all 16 cells of the 4 x 4 (0.4 degree box) are the same point. Every cell copies the one
# regional column nearest to LAT/LON (NWA25 i=300, j=331), and the atmosphere is read there too.
# For another column change LAT, LON, DEPTH (its depth) and the "por" value in model/data_table.
LAT=43.84613
LON=-67.23395
DEPTH=156.3                # flat bottom [m]

# --- model -------------------------------------------------------------------
# the MOM6SIS2 executable (sinksource or biot_bioi build)
EXE=/home/d.sasaki/schultz/d.sasaki/compilation/explorer/202607_CBED1.0_betav4_sinksource/builds/build/explorer-intel/ocean_ice/repro/MOM6SIS2
# regional CBED solution: step 2 copies its wet column nearest to LAT/LON into every cell
CBED_IC=/home/d.sasaki/schultz/d.sasaki/km_scale_model/mom6cobalt_25th/20240723_zstar/tasks/202611_cbed_R2py/data1/cbed_results.nc
# step 5 only (5_spinup_cbed.py): one year of a run of this experiment (settings: cbed_spinup.toml), and the
# CBED tools folder: its pixi env (python, R, rpy2, cbed2py) and scripts/cbed_wrapper.py (PYTHONPATH)
CBED_FORCING_RUN=
CBED_TOOLS=

# --- run ---------------------------------------------------------------------
MODE=repeat                # repeat: YEAR0 repeated NSEG times | sequential: years YEAR0..YEAR1
YEAR0=2018
YEAR1=2018                 # sequential mode only
NSEG=10                    # repeat mode only
IC_MODE=cold               # cold (GLORYS + WOA/ESPER files) | restart (the restart files in IC_RESTART)
IC_RESTART=                # a folder with a copy of a RESTART_segNN; only used if IC_MODE=restart
SEGS_PER_JOB=10            # segments per Slurm job; then run.sh submits the next job

# --- nudging -----------------------------------------------------------------
SPONGE_TAU=30              # nudging timescale [days], the same for every variable

# --- data --------------------------------------------------------------------
IC_DIR=/home/d.sasaki/schultz/d.sasaki/experiments/inputs_ref/20260622_consolidating_inputs    # initial T, S (glorys_ic_*) and BGC (bgc_woa_esper_ics_*)
DATASETS=/scratch/d.sasaki/mom_experiments2/202610_cbed_1D/CEFI-regional-MOM6/exps/datasets/station_1d
DEPOSITION_DIR=/projects/schultz/d.sasaki/km_scale_model/mom6cobalt_25th/mom_tools/data/other    # esm4_{dry,wet}{fe,dust,noy,nh4}_climo_1993-2014.nc
GLORYS_DIR=/home/d.sasaki/schultz/data/glorys/nwa25_regional/monthly_average
COBALT_DIR=/home/d.sasaki/scratch/mom_experiments2/202611_cbed/202611_nocbed/outputs_raw/raw    # 202611_nocbed monthly means, 2018-01..2021-02
ERA5_DIR=/home/d.sasaki/schultz/d.sasaki/experiments/inputs_ref/20260622_consolidating_inputs    # ERA5_<var>_<year>_padded.nc, 1993-2025

# --- tools -------------------------------------------------------------------
# the repository clone (the folder with pixi.toml, see README); the default works inside the repo
PIXI_ROOT=$(dirname "$PWD")

export PATH="$PIXI_ROOT/.pixi/envs/default/bin:$PIXI_ROOT/opt/fre-nctools/bin:$PATH"
