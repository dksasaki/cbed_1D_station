#!/usr/bin/env python3
"""
Step 2 - the CBED initial state for the station.

Reads   config.sh                STATION, CBED_IC (a regional CBED solution)
        model/INPUT/ocean_hgrid.nc     the station grid from step 1
Writes  model/INPUT/cbed/<STATION>/generic_CBED.res.nc
        model/INPUT/cbed/<STATION>/build.log    which regional column fed each station cell
        model/INPUT/cbed/<STATION>/source.txt   the regional file used
        model/INPUT/generic_CBED.res.nc         link to the state above

Why: FMS reads restart files without interpolation, so CBED's initial state
must already be on the 4 x 4 station grid. Each station cell copies the
nearest "wet" column of the regional solution: organic matter (and
porosity) > 0 in the top sediment layer.
"""
import os

import numpy as np
import xarray as xr


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
os.makedirs(folder, exist_ok=True)

# --- 1. the station cells: centres of the 4 x 4 grid (the odd points of the supergrid)
grid = xr.open_dataset("model/INPUT/ocean_hgrid.nc")
lon = grid["x"].values[1::2, 1::2]
lat = grid["y"].values[1::2, 1::2]

# --- 2. the regional solution
# mask_and_scale=False keeps its fill values as they are, so the station file holds the same numbers
regional = xr.open_dataset(config["CBED_IC"], decode_times=False, mask_and_scale=False)
layer_dim = [d for d in regional["cbed_o2"].dims if d not in ("x", "y")][0]     # the sediment layer axis

# --- 3. its wet columns: organic matter > 0 in the top layer, and porosity > 0
top_om = regional["cbed_om1"].isel({layer_dim: 0}).values.astype(float)
wet = np.isfinite(top_om) & (top_om > 0)
if "porosity" in regional:
    porosity = regional["porosity"].values.astype(float)
    wet = wet & np.isfinite(porosity) & (porosity > 0)
wet_j, wet_i = np.nonzero(wet)
wet_lon = regional["x"].values[wet_i]
wet_lat = regional["y"].values[wet_j]

# --- 4. for each station cell, the nearest wet column
coslat = np.cos(np.deg2rad(lat.mean()))          # a degree of longitude is shorter than one of latitude
pick_j = np.zeros(lon.shape, dtype=int)
pick_i = np.zeros(lon.shape, dtype=int)
report = []
for j in range(lon.shape[0]):
    for i in range(lon.shape[1]):
        dist2 = ((wet_lon - lon[j, i]) * coslat) ** 2 + (wet_lat - lat[j, i]) ** 2
        k = int(np.argmin(dist2))
        pick_j[j, i] = wet_j[k]
        pick_i[j, i] = wet_i[k]
        report.append(f"cell ({i + 1},{j + 1}) {lat[j, i]:8.3f}N {lon[j, i]:9.3f}E <- regional "
                      f"(i={wet_i[k]}, j={wet_j[k]}) {wet_lat[k]:8.3f}N {wet_lon[k]:9.3f}E, "
                      f"{np.sqrt(dist2[k]) * 111.0:5.1f} km")

# --- 5. copy those columns: every 3-D (layer, y, x) and 2-D (y, x) field except porosity
fields = []
for name in regional.data_vars:
    if name != "porosity" and regional[name].dims in ((layer_dim, "y", "x"), ("y", "x")):
        fields.append(name)

station = regional[fields].isel(y=xr.DataArray(pick_j, dims=("y", "x")),
                                x=xr.DataArray(pick_i, dims=("y", "x")))
station = station.drop_vars(["x", "y"], errors="ignore")          # the regional coordinates
station = station.rename({layer_dim: "lev"})                      # generic_CBED.F90 calls the layer axis 'lev'
station = station.assign_coords(x=("x", lon[0, :], regional["x"].attrs),
                                y=("y", lat[:, 0], regional["y"].attrs))

for name in fields:
    bad = ~np.isfinite(station[name].values)
    if bad.any():
        report.append(f"WARNING: {name} has {int(bad.sum())} non-finite values, set to 0")
        station[name] = station[name].where(~bad, 0)

station.attrs = dict(regional.attrs)
station.attrs["source"] = os.path.realpath(config["CBED_IC"])
station.attrs["history"] = "cut to the station grid by 2_make_cbed.py"

# --- 6. write it like the regional file: same dtypes and fill values, NetCDF3 like the model's restarts
encoding = {}
for name in station.variables:
    source_name = layer_dim if name == "lev" else name
    dtype = regional[source_name].dtype if source_name in regional.variables else station[name].dtype
    encoding[name] = {"dtype": dtype, "_FillValue": station[name].attrs.pop("_FillValue", None)}
station.to_netcdf(f"{folder}/generic_CBED.res.nc", format="NETCDF3_64BIT_OFFSET", encoding=encoding)

with open(f"{folder}/build.log", "w") as f:
    f.write("\n".join(report) + "\n")
with open(f"{folder}/source.txt", "w") as f:
    f.write(os.path.realpath(config["CBED_IC"]) + "\n")

# --- 7. check: the model expects a 4 x 4 file with a 'lev' axis
check = xr.open_dataset(f"{folder}/generic_CBED.res.nc", decode_times=False)
assert (check.sizes["y"], check.sizes["x"]) == (4, 4), "CBED state is not 4 x 4"
assert "lev" in check.dims, "CBED state has no 'lev' axis"

# --- 8. the model reads model/INPUT/generic_CBED.res.nc (run.sh links it again before every cold start)
if os.path.lexists("model/INPUT/generic_CBED.res.nc"):
    os.remove("model/INPUT/generic_CBED.res.nc")
os.symlink(f"cbed/{config['STATION']}/generic_CBED.res.nc", "model/INPUT/generic_CBED.res.nc")

print("\n".join(report))
print(f"Step 2 done: {folder}/generic_CBED.res.nc")
