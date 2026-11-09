# station_1d_simple

A single-column MOM6 + SIS2 + COBALT + CBED experiment at one station: a
0.4° box of 4 × 4 ocean cells with a flat bottom, nudged toward GLORYS
(T, S) and NEUS25 COBALT (O2, NO3, PO4, SiO4, DIC, Alk).

**This folder is the experiment.** Copy it, edit `config.sh`, and run the
steps below in order. The scripts at the top prepare the model. `model/`
is the model's run directory: everything MOM6 reads and writes, and nothing
else.

```
my_experiment/
├── README.md
├── config.sh                 the settings
├── experiment.txt            summary of the settings (written by step 0)
├── 0_link_data.sh            preparation steps, run in order
├── 1_make_grid.sh
├── 2_make_cbed.py
├── 3_make_sponge.py
├── 4_make_jpoc.py
├── run.sh                    runs the model inside model/
├── run_<jobid>.out           Slurm logs
└── model/                    the run directory
    ├── MOM_input, MOM_override, SIS_*, COBALT_*, field_table, data_table,
    │   diag_table*, input.nml.base, env.sh
    ├── mom6 -> the executable
    ├── INPUT/
    │   ├── grids/<STATION>/     grid files + make_*.log
    │   ├── cbed/<STATION>/      generic_CBED.res.nc, build.log, source.txt (+ fntot_btm_mean.nc)
    │   ├── sponge/<STATION>/    sponge_ts/bgc/damping.nc, build.log, build.txt
    │   └── *.nc                 links into the folders above, or to DATASETS
    ├── history/<segment>/       output of each segment
    └── RESTART_<segment>/       restarts at the end of each segment
```

## Building the experiment

```bash
# once per clone, in the repository folder: see "Installing the tools" below
pixi install && pixi run install-fre-nctools

cp -r station_1d_simple /path/to/my_experiment
cd /path/to/my_experiment

# edit config.sh: station, executable, run mode, data paths, PIXI_ROOT
source config.sh                # puts FRE-NCtools and python on PATH (once per shell)

./0_link_data.sh                # global inputs  -> model/INPUT/*.nc (links), model/mom6, experiment.txt
./1_make_grid.sh                # station grid   -> model/INPUT/grids/<STATION>/
python3 2_make_cbed.py          # CBED initial state -> model/INPUT/cbed/<STATION>/
python3 3_make_sponge.py        # nudging files  -> model/INPUT/sponge/<STATION>/   (a few minutes)
python3 4_make_jpoc.py          # ONLY for the biot_bioi executable, see below

sbatch -J $(basename $PWD) run.sh    # run, as a job named after the experiment
```

All steps are run from the experiment folder (the top), not from `model/`.

| step | what it does | reads | writes |
|---|---|---|---|
| `0_link_data.sh` | links the files that are the same everywhere (initial conditions, deposition, porosity) and the executable; writes the summary | `DATASETS`, `POROSITY`, `EXE` | `model/INPUT/*.nc`, `model/mom6`, `experiment.txt` |
| `1_make_grid.sh` | builds the grid with FRE-NCtools | `LAT`, `LON`, `DEPTH` | `model/INPUT/grids/<STATION>/` (+ one `.log` per program) |
| `2_make_cbed.py` | copies the nearest wet column of a regional CBED solution into each cell | `CBED_IC` | `model/INPUT/cbed/<STATION>/generic_CBED.res.nc`, `build.log`, `source.txt` |
| `3_make_sponge.py` | monthly means at the station → nudging files | `MODE`, `YEAR0/1`, `SPONGE_TAU`, `GLORYS_DIR`, `COBALT_DIR` | `model/INPUT/sponge/<STATION>/sponge_ts.nc`, `sponge_bgc.nc`, `sponge_damping.nc`, `build.log`, `build.txt` |
| `4_make_jpoc.py` | mean POC flux for the biot_bioi build | `COBALT_DIR`, `YEAR0` | `model/INPUT/cbed/<STATION>/fntot_btm_mean.nc` |
| `run.sh` | runs the segments in `model/`, `SEGS_PER_JOB` per job, then submits the next job | `MODE`, `YEAR0/1`, `NSEG`, `SEGS_PER_JOB`, `DATASETS` | `model/history/<seg>/`, `model/RESTART_<seg>/` |

**Jobs.** This follows how the GofME experiments were run. Each job runs at
most `SEGS_PER_JOB` new segments (default 10; a segment takes about 35–45
min, and the limit is 8 h). If segments remain, it submits the next job
under the same name, until all are done. A failed segment stops the chain;
fix the problem and `sbatch` again, which continues after the last finished
segment. For a slow station (the slope runs took up to 46 min per segment),
use `SEGS_PER_JOB=9`. To run everything in one long job instead, set
`SEGS_PER_JOB` to `NSEG` and submit with a longer limit, e.g.
`sbatch -J name --time=1-12:00:00 run.sh`.

## Run modes (`MODE` in `config.sh`)

| mode | what runs | segments |
|---|---|---|
| `repeat` | year `YEAR0`, `NSEG` times. The state carries on; the clock goes back to Jan 1. | `seg01 … segNN` |
| `sequential` | the real years `YEAR0 … YEAR1` | `1993, 1994, …` |

Steps 3 and `run.sh` read `MODE`. If you change it, rerun step 3.

## Templates of model files (`model/`)

These are plain files. Nothing generates them.

| file | what to change |
|---|---|
| `model/MOM_override` | **nudging**: the block at the end. To run without it, set `SPONGE` and `DO_SPONGE_GENERIC_TRACER` to `False` |
| `model/data_table` | **biot_bioi executable**: uncomment the `cbed_jpoc_mean` line (and run step 4). CO2 is a constant 360 ppm here |
| `model/diag_table` | output. `diag_table_no_daily` (default) or `diag_table_with_daily`: `ln -sf diag_table_with_daily model/diag_table` |
| `model/input.nml.base` | the namelist. `run.sh` fills in the `@...@` placeholders for each segment and writes `model/input.nml` |
| `model/MOM_input`, `model/SIS_*`, `model/field_table` | the physics and BGC setup, shared with the other station templates |

## Installing the tools (pixi)

Steps 1–4 need python (numpy, xarray, dask, netCDF4, cftime) and the
FRE-NCtools programs. `pixi.toml`, in the repository folder (one level up),
installs both there. Install [pixi](https://pixi.sh) and then run, once per
clone, in the repository folder:

```bash
pixi install                    # python, nco, netCDF, compilers -> .pixi/
pixi run install-fre-nctools    # clones and builds FRE-NCtools  -> opt/fre-nctools/bin/
```

`install_fre_nctools.sh` does the build: it clones
[FRE-NCtools](https://github.com/NOAA-GFDL/FRE-NCtools) into
`opt/FRE-NCtools-src/`, then runs `autoreconf`, `configure`, `make` and
`make install` with the compilers and netCDF from `.pixi/`.

`source config.sh` then puts `$PIXI_ROOT/.pixi/envs/default/bin` and
`$PIXI_ROOT/opt/fre-nctools/bin` on PATH (no `pixi shell` needed). All
experiments share this one installation. `PIXI_ROOT` defaults to the folder
above the experiment, which is right for `station_1d_simple` inside the
repository. For a copy elsewhere, set it to the path of the clone.

The model (`run.sh`) does not use this environment. It uses `model/env.sh`.



## Limits

- NEUS25 COBALT in `COBALT_DIR` has **1993 only**. Step 3 needs every month of the run years, so nudging works for 1993 until more years are added.
- JRA55-do forcing exists for 1993–1997.
- The biot_bioi executable **stops** if the `cbed_jpoc_mean` line is commented. The sinksource executable ignores it.


