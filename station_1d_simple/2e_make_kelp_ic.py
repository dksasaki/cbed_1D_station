#!/usr/bin/env python3
"""
Step 2e - the kelp pools in the CBED initial state (needed with do_external_source).

Reads   config.sh                                         STATION
        model/INPUT/cbed/<STATION>/generic_CBED.res.nc    the CBED state from step 2 (or 5)
Writes  the same file, with cbed_om1_kelp, cbed_om2_kelp, cbed_om3_kelp added if missing,
        and a line in model/INPUT/cbed/<STATION>/build.log

Why: with do_external_source, CBED keeps the kelp-sourced share of OM1-3 in pools of its
own and reads them from INPUT/generic_CBED.res.nc even on a cold start; the model stops
if they are missing. A run without kelp has no kelp material, so each pool starts at zero,
laid out like cbed_om1..3, as in the earlier 20260824_kelp_stresstest inputs
(cbed_init_new.nc). The regional CBED solution that step 2 copies has no kelp pools.
(COBALT's ndet_kelp needs no file: it starts at zero through model/field_table.)

Rerun after steps 2 or 5, which rewrite the file. Pools already there are kept, so a
second run changes nothing. Without do_external_source the model ignores them.
"""
import os

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
folder = f"model/INPUT/cbed/{config['STATION']}"
path = f"{folder}/generic_CBED.res.nc"

# mask_and_scale=False keeps the fill values as they are, so the rewritten file holds the same numbers
state = xr.open_dataset(path, decode_times=False, mask_and_scale=False).load()
state.close()
missing = {pool: like for pool, like in POOLS.items() if pool not in state}

if missing:
    for pool, like in missing.items():
        state[pool] = xr.zeros_like(state[like])
        state[pool].attrs["long_name"] = f"kelp-sourced {like}"
    # write it like steps 2 and 5: same dtypes and fill values, NetCDF3
    encoding = {name: {"dtype": state[name].dtype, "_FillValue": state[name].attrs.pop("_FillValue", None)}
                for name in state.variables}
    state.to_netcdf(f"{path}.tmp", format="NETCDF3_64BIT", encoding=encoding)
    os.replace(f"{path}.tmp", path)          # INPUT/generic_CBED.res.nc links here, so it stays valid
    line = f"2e_make_kelp_ic.py: added {', '.join(missing)} (zeros)"
else:
    line = f"2e_make_kelp_ic.py: {', '.join(POOLS)} already present"

with open(f"{folder}/build.log", "a") as f:
    f.write(line + "\n")
print(f"{path}: {line.split(': ', 1)[1]}")
print("Step 2e done")
