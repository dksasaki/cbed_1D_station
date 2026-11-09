# Single-column MOM6 + SIS2 + COBALT + CBED at a station

```
./
├── README.md
├── pixi.toml, pixi.lock      the tools for the preparation steps (python, nco, FRE-NCtools build)
├── install_fre_nctools.sh    builds FRE-NCtools into opt/  (pixi run install-fre-nctools)
├── .pixi/, opt/              the installed tools (not in git)
├── station_1d_simple/        the template: copy it to make an experiment. See its README.
└── legacy/                   the earlier template, kept for reference
```

## 1. Install the tools (once per clone)

Install [pixi](https://pixi.sh), then, in this folder:

```bash
pixi install                    # python, nco, netCDF, compilers -> .pixi/
pixi run install-fre-nctools    # clones and builds FRE-NCtools  -> opt/fre-nctools/bin/
```

## 2. Make an experiment

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