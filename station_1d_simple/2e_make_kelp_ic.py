#!/usr/bin/env python3
"""
Step 2e - the kelp pools in the CBED initial state (needed with do_external_source).

Reads   config.sh                                         STATION
        kelp.toml                                         [ic] cbed: true to create the file below
        model/INPUT/cbed/<STATION>/generic_CBED.res.nc    the CBED state from step 2 (or 5), not modified
Writes  model/INPUT/cbed/<STATION>/generic_CBED.res.kelp.nc   that state + cbed_om1/2/3_kelp
        a line in model/INPUT/cbed/<STATION>/build.log

Why: with do_external_source, CBED keeps the kelp-sourced share of OM1-3 in pools of its
own and reads them from INPUT/generic_CBED.res.nc even on a cold start; the model stops
if they are missing. A run without kelp has no kelp material, so each pool starts at zero,
laid out like cbed_om1..3, as in the earlier 20260824_kelp_stresstest inputs
(cbed_init_new.nc). The regional CBED solution that step 2 copies has no kelp pools.
(COBALT's ndet_kelp needs no file: it starts at zero through model/field_table.)

run.sh starts CBED from generic_CBED.res.kelp.nc when it exists, and stops if it is older
than generic_CBED.res.nc: rerun this step after steps 2 or 5. With [ic] cbed = false
nothing is created; delete an earlier kelp file to start CBED from the step 2/5 state.
"""
import os
import tomllib

import xarray as xr

POOLS = {"cbed_om1_kelp": "cbed_om1", "cbed_om2_kelp": "cbed_om2", "cbed_om3_kelp": "cbed_om3"}


def read_config(path="config.sh"):
    """The KEY=value lines of config.sh, without comments and quotes."""
    config = {}
    for line in open(path):
        line = line.split("#")[0].strip()
        if "=" in line and not line.startswith("export"):
            key, value = line.split("=", 1)
            config[key.strip()] = value.strip().strip('"')
    return config


config = read_config()
with open("kelp.toml", "rb") as f:
    kelp = tomllib.load(f)
folder = f"model/INPUT/cbed/{config['STATION']}"
source = f"{folder}/generic_CBED.res.nc"
target = f"{folder}/generic_CBED.res.kelp.nc"

if not kelp["ic"]["cbed"]:
    note = " (an earlier one exists: run.sh will use it; delete it to start from the step 2/5 state)"
    print(f"Step 2e skipped ([ic] cbed = false in kelp.toml){note if os.path.exists(target) else ''}")
    raise SystemExit

# mask_and_scale=False keeps the fill values as they are, so the copy holds the same numbers
with xr.open_dataset(source, decode_times=False, mask_and_scale=False) as f:
    state = f.load()
added = [pool for pool in POOLS if pool not in state]
for pool in added:
    state[pool] = xr.zeros_like(state[POOLS[pool]])
    state[pool].attrs["long_name"] = f"kelp-sourced {POOLS[pool]}"
state.attrs["history"] = f"{os.path.realpath(source)} + kelp pools (zeros), by 2e_make_kelp_ic.py"

# write it like steps 2 and 5: same dtypes and fill values, NetCDF3
encoding = {name: {"dtype": state[name].dtype, "_FillValue": state[name].attrs.pop("_FillValue", None)}
            for name in state.variables}
state.to_netcdf(target, format="NETCDF3_64BIT", encoding=encoding)

line = f"2e_make_kelp_ic.py: created {target} = {source} + {', '.join(added) or 'no new pools'} (zeros)"
with open(f"{folder}/build.log", "a") as f:
    f.write(line + "\n")
print(line)
print("Step 2e done: run.sh starts CBED from it")
