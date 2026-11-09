#!/bin/bash
#
# Station monthly means for the sponge files (step 1 of setup_sponge_station.sh).
#
#   sbatch submit_sponge.sh            # GofME
#   sbatch submit_sponge.sh <name>     # another station built with setup_station.sh

#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=8G
#SBATCH --time=04:00:00
#SBATCH --job-name="sponge_monthly"
#SBATCH --output=sponge.out
#SBATCH --error=sponge.err
#SBATCH --partition=short

set -e

station="${1:-GofME}"
expdir=/home/d.sasaki/scratch/mom_experiments2/202610_cbed_1D/OM4.single_column.COBALT.station

# python3 with netCDF4 and cftime, independent of the submitting shell
export PATH="/projects/schultz/d.sasaki/km_scale_model/mom6cobalt_25th/20240723_zstar/tasks/202603_tasks_seabed/general_evaluation/.pixi/envs/default/bin:$PATH"

echo "Sponge monthly means for $station started:  " `date`

cd "$expdir"
./setup_sponge_station.sh "$station" monthly

echo "Sponge monthly means for $station ended:    " `date`
