# Single-column MOM6 + SIS2 + COBALT + CBED at a station

> **Note.** This setup was built and run on a private HPC system. It does
> **not** include instructions to compile the MOM6-SIS2-COBALT-CBED
> executable: you need your own build (`EXE` in `config.sh`). Several
> configuration files hold paths, modules and job settings of that system:
> **edit them before running anything**, see
> [Configuration files to edit](#configuration-files-to-edit).

```
./
├── README.md
├── pixi.toml, pixi.lock      the tools for the preparation steps (python, nco, FRE-NCtools build)
├── install_fre_nctools.sh    builds FRE-NCtools into opt/  (pixi run install-fre-nctools)
├── .pixi/, opt/              the installed tools (not in git)
├── station_1d_simple/        the template: copy it to make an experiment. See its README.
└── legacy/                   the earlier template, kept for reference
```

## 1. Get the code

```bash
git clone https://github.com/dksasaki/cbed_1D_station.git
cd cbed_1D_station
```

## 2. Install the tools (once per clone)

Install [pixi](https://pixi.prefix.dev/latest/installation/), then, in this folder:

```bash
pixi install                    # python, nco, netCDF, compilers -> .pixi/
pixi run install-fre-nctools    # clones and builds FRE-NCtools  -> opt/fre-nctools/bin/
```

## 3. Make an experiment

```bash
cp -r station_1d_simple /path/to/my_experiment
```

In the copy, edit the configuration files listed below, then follow
[station_1d_simple/README.md](station_1d_simple/README.md).

The model run (`run.sh`) does not use the pixi tools. It loads the
compilers and libraries the executable was built with, from `model/env.sh`,
which is specific to the cluster.

## Configuration files to edit

All of them are plain text files in the experiment copy. Nothing generates
them, and the values in git are those of the system this setup was built on.

**For your system (always):**

| file | what to change |
|---|---|
| `config.sh` | `EXE` (your MOM6SIS2 build); the input data paths `CBED_IC`, `IC_DIR`, `DATASETS`, `DEPOSITION_DIR`, `GLORYS_DIR`, `COBALT_DIR`, `ERA5_DIR`; `PIXI_ROOT` = the path of this clone, if the experiment is not inside it |
| `model/env.sh` | the modules and library paths (compilers, MPI, netCDF) your executable was built with, and the MPI/UCX settings of your cluster |
| `run.sh` | the `#SBATCH` lines at the top (partition, constraint, time limit) for your scheduler |

**For your station:**

| file | what to change |
|---|---|
| `config.sh` | `STATION`, `LAT`, `LON` and `DEPTH` (the depth of the regional column nearest to `LAT`/`LON`) |
| `model/data_table` | the `por` line: the CBED porosity of that column (the `porosity_final.nc` value nearest to it) |

**For your run (as needed):**

| file | what to change |
|---|---|
| `config.sh` | `MODE`, `YEAR0`/`YEAR1`, `NSEG`, `IC_MODE`/`IC_RESTART`, `SEGS_PER_JOB`, `SPONGE_TAU` |
| `model/MOM_override` | nudging on/off (the block at the end) |
| `model/diag_table` | the output (a link to `diag_table_no_daily` or `diag_table_with_daily`) |
| `cbed_spinup.toml` | settings of the optional CBED spin-up (step 5) |
| `kelp.toml` | the kelp forcing (steps 2d, 2e): source and sink rates, active windows, sink depth range, and whether step 2e creates the kelp CBED state |
| `model/COBALT_input` | `do_external_source` / `do_external_sink`: the kelp switches COBALT reads. Keep them equal to `enabled` in `kelp.toml` (and to the same entries in `model/input.nml.base`, which COBALT does not read) |

[station_1d_simple/README.md](station_1d_simple/README.md) explains each
setting where it is used.

## Disclaimer
The instructions, and parts of the code used for submission were written with Claude (Anthropic).

This experiments were originally created based on [Jessica Luo's OM5.single_column.COBALT.station](https://github.com/jessluo/CEFI-regional-MOM6/tree/add-relocatable-single-column-station/exps/OM4.single_column.COBALT.station) and [MOM6-COBALT-NEUS25](https://github.com/dksasaki/MOM6_COBALT_NEUS25)