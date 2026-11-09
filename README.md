# Single-column MOM6 + SIS2 + COBALT + CBED at a station

> **Note.** This setup was built and run on a private HPC system. It does
> **not** include instructions to compile the MOM6-SIS2-COBALT-CBED
> executable: you need your own build (`EXE` in `config.sh`). The paths in
> `config.sh` (executable, input data) and the modules and libraries in
> `model/env.sh` are those of that system, and must be changed for yours.

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

Edit `config.sh` in the copy (station, executable, data paths, and
`PIXI_ROOT` = the path of this folder), then follow
[station_1d_simple/README.md](station_1d_simple/README.md).

The model run (`run.sh`) does not use the pixi tools. It loads the
compilers and libraries the executable was built with, from `model/env.sh`,
which is specific to the cluster.

## Disclaimer
The instructions, and parts of the code used for submission were written with Claude (Anthropic).

This experiments were originally created based on [Jessica Luo's OM5.single_column.COBALT.station](https://github.com/jessluo/CEFI-regional-MOM6/tree/add-relocatable-single-column-station/exps/OM4.single_column.COBALT.station) and [MOM6-COBALT-NEUS25](https://github.com/dksasaki/MOM6_COBALT_NEUS25)