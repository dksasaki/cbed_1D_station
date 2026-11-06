#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=08:00:00
#SBATCH --partition=short
#SBATCH --constrain=ib,cascadelake
#SBATCH --job-name=1d_cbed
#SBATCH --output=run_%j.out
#
# Run the experiment, from this directory:
#
#   sbatch -J $(basename $PWD) run.sh
#
# MODE=repeat      segments seg01..segNN, each simulating YEAR0; the ocean, ice,
#                  BGC and sediment state carries on, the clock goes back to Jan 1
# MODE=sequential  segments YEAR0..YEAR1, each simulating its own year
#
# Jobs, as done for the GofME experiments: each job runs at most SEGS_PER_JOB
# new segments (a segment takes ~35-45 min, so 10 fit in the 8-hour limit),
# then submits the next job under the same name, until all segments are done.
# Finished segments (RESTART_<segment> exists) are always skipped, so
# "sbatch run.sh" by hand also continues where the last job stopped.
# A failed segment stops the chain; nothing is resubmitted.
#
# The model runs inside model/ (its run directory). Output, also in model/:
#          history/<segment>/    diagnostics, ocean.stats, model.out/.err
#          RESTART_<segment>/    restart files at the end of the segment
#
set -e
# go to the experiment folder: the folder of this script, or, under sbatch (which runs
# a copy of the script from Slurm's spool folder), the folder it was submitted from
here="$(cd "$(dirname "$0")" && pwd)"
if [ -e "$here/config.sh" ]; then
    cd "$here"
else
    cd "$SLURM_SUBMIT_DIR"
fi
source config.sh
experiment_dir="$PWD"
experiment=$(basename "$PWD")

# from here on, work in the model's run directory
cd model
source env.sh

if [ "$MODE" = repeat ]; then
    SEGMENTS=$(seq -f "seg%02g" 1 "$NSEG")
else
    SEGMENTS=$(seq "$YEAR0" "$YEAR1")
fi

previous=""
done_in_this_job=0
for segment in $SEGMENTS; do

    # 1. a finished segment is skipped
    if [ -d "RESTART_$segment" ]; then
        previous=$segment
        continue
    fi

    # 1b. this job has done its share: submit the next job (same name) and stop
    if [ "$done_in_this_job" -ge "$SEGS_PER_JOB" ]; then
        echo "=== $done_in_this_job segments done in this job; submitting the next job"
        cd "$experiment_dir"
        sbatch -J "$experiment" run.sh
        exit 0
    fi

    # 2. the year this segment simulates
    if [ "$MODE" = repeat ]; then
        year=$YEAR0
    else
        year=$segment
    fi
    echo "=== $segment (year $year) started $(date '+%F %T')"

    # 3. leftovers of an earlier, failed attempt are moved to failed/
    if [ -e "history/$segment" ] || [ -e RESTART ]; then
        keep="failed/${segment}_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$keep"
        if [ -e "history/$segment" ]; then mv "history/$segment" "$keep/"; fi
        if [ -e RESTART ]; then mv RESTART "$keep/"; fi
        echo "    earlier attempt moved to model/$keep"
    fi

    # 4. the atmospheric forcing of that year (JRA55-do v1.5.0)
    for v in huss prra prsn psl rlds rsds tas uas vas; do
        ln -sf "$DATASETS"/${v}_*JRA55-do-1-5-0_gr_${year}*.padded.nc "INPUT/JRA_$v.nc"
        if [ ! -e "INPUT/JRA_$v.nc" ]; then
            echo "ERROR: no JRA55-do forcing for $v in $year" >&2
            exit 1
        fi
    done

    # 5. the initial state
    #    remove the restart links of the previous segment (and a stale coupler.res,
    #    which would otherwise set the start date), then link the cold-start CBED state
    find INPUT -maxdepth 1 -type l -lname '../RESTART_*' -delete
    rm -f INPUT/coupler.res
    ln -sf "cbed/$STATION/generic_CBED.res.nc" INPUT/generic_CBED.res.nc
    if [ -z "$previous" ]; then
        start=n                                     # cold start
        force_date=.false.
    else
        (cd INPUT && ln -sf ../RESTART_$previous/* .)      # continue from the previous segment
        start=r
        if [ "$MODE" = repeat ]; then
            force_date=.true.                       # reset the clock to YEAR0-01-01
        else
            force_date=.false.
        fi
    fi

    # 6. the namelist of this segment: input.nml.base with its @...@ placeholders filled in
    mkdir -p "history/$segment" RESTART
    sed -e "s|@OUTPUT_DIR@|history/$segment/|g" \
        -e "s|@INPUT_FILENAME@|$start|g" \
        -e "s|@START_YEAR@|$year|" \
        -e "s|@FORCE_DATE@|$force_date|" \
        -e "s|@MONTHS@|12|" \
        -e "s|@DAYS@|0|" \
        input.nml.base > input.nml

    # 7. run the model
    mpiexec -np 1 ./mom6 > "history/$segment/model.out" 2> "history/$segment/model.err"
    if [ ! -f RESTART/generic_CBED.res.nc ]; then
        echo "ERROR: $segment wrote no RESTART/generic_CBED.res.nc, see model/history/$segment/model.err" >&2
        exit 1
    fi

    # 8. keep the output of this segment
    for f in [0-9]*.nc; do
        if [ -e "$f" ]; then mv "$f" "history/$segment/"; fi
    done
    mv RESTART "RESTART_$segment"
    previous=$segment
    done_in_this_job=$((done_in_this_job + 1))
    echo "=== $segment finished $(date '+%F %T')"
done

echo "All segments done."
