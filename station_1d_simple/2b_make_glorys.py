#!/usr/bin/env python3
"""
Step 2b - the temperature, salinity and sea surface height initial state for the station.

Reads   config.sh                      STATION, IC_DIR, YEAR0
        $IC_DIR/glorys_ic_<YEAR0>-01-01.nc   the regional GLORYS state (NWA25 grid, 396 x 430)
        $IC_DIR/ocean_hgrid.nc, ocean_topog.nc   the regional grid that file sits on
        model/INPUT/ocean_hgrid.nc     the station grid from step 1
Writes  model/INPUT/glorys/<STATION>/glorys_ic_station.nc
        model/INPUT/glorys/<STATION>/build.log   which regional cell fed each station cell
        model/INPUT/glorys/<STATION>/source.txt  the regional file used
        model/INPUT/glorys_ic_station.nc         link to the state above

Why: the regional file has no longitudes or latitudes, so MOM6 cannot interpolate
it onto the station (INIT_LAYERS_FROM_Z_FILE fails in hinterp_extrap). Like
the regional run, the station reads its state straight from a file that sits on
the model grid (TS_CONFIG = "file"). Each station cell copies the nearest ocean
cell of the regional file, for every level, so the file is 4 x 4 with the same
75 levels.
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
source = os.path.join(config["IC_DIR"], f"glorys_ic_{config['YEAR0']}-01-01.nc")
folder = f"model/INPUT/glorys/{config['STATION']}"
os.makedirs(folder, exist_ok=True)

# --- 1. the station cells: centres of the 4 x 4 grid (the odd points of the supergrid)
grid = xr.open_dataset("model/INPUT/ocean_hgrid.nc")
lon = grid["x"].values[1::2, 1::2]
lat = grid["y"].values[1::2, 1::2]

# --- 2. the regional cells: centres of its supergrid, and where it is ocean
regional_grid = xr.open_dataset(os.path.join(config["IC_DIR"], "ocean_hgrid.nc"))
regional_lon = regional_grid["x"].values[1::2, 1::2]
regional_lat = regional_grid["y"].values[1::2, 1::2]
depth = xr.open_dataset(os.path.join(config["IC_DIR"], "ocean_topog.nc"))["depth"].values

# mask_and_scale=False keeps the numbers exactly as they are in the regional file
regional = xr.open_dataset(source, decode_times=False, mask_and_scale=False)
assert regional["temp"].shape[-2:] == regional_lon.shape == depth.shape, \
    f"{source} {regional['temp'].shape[-2:]} is not on the grid of {config['IC_DIR']}/ocean_hgrid.nc {regional_lon.shape}"

ocean = np.isfinite(depth) & (depth > 0)
ocean_j, ocean_i = np.nonzero(ocean)
ocean_lon = regional_lon[ocean_j, ocean_i]
ocean_lat = regional_lat[ocean_j, ocean_i]

# --- 3. for each station cell, the nearest ocean cell
coslat = np.cos(np.deg2rad(lat.mean()))          # a degree of longitude is shorter than one of latitude
pick_j = np.zeros(lon.shape, dtype=int)
pick_i = np.zeros(lon.shape, dtype=int)
report = []
for j in range(lon.shape[0]):
    for i in range(lon.shape[1]):
        dist2 = ((ocean_lon - lon[j, i]) * coslat) ** 2 + (ocean_lat - lat[j, i]) ** 2
        k = int(np.argmin(dist2))
        pick_j[j, i] = ocean_j[k]
        pick_i[j, i] = ocean_i[k]
        report.append(f"cell ({i + 1},{j + 1}) {lat[j, i]:8.3f}N {lon[j, i]:9.3f}E <- regional "
                      f"(i={ocean_i[k]}, j={ocean_j[k]}) {ocean_lat[k]:8.3f}N {ocean_lon[k]:9.3f}E, "
                      f"depth {depth[ocean_j[k], ocean_i[k]]:6.1f} m, {np.sqrt(dist2[k]) * 111.0:5.1f} km")

# --- 4. copy those columns: temp, salt (zl, yh, xh) and ssh (yh, xh)
# u and v are left out: the station does not read them, and they sit on other points (xq, yq)
fields = [name for name in ("temp", "salt", "ssh") if name in regional]
pick = dict(yh=xr.DataArray(pick_j, dims=("yh", "xh")), xh=xr.DataArray(pick_i, dims=("yh", "xh")))

station = regional[fields].isel(pick)
station = station.assign_coords(zl=regional["zl"], time=regional["time"])
station = station.assign_coords(xh=("xh", lon[0, :], {"long_name": "h point longitude", "units": "degrees_east"}),
                                yh=("yh", lat[:, 0], {"long_name": "h point latitude", "units": "degrees_north"}))

for name in fields:
    bad = ~np.isfinite(station[name].values)
    if bad.any():
        report.append(f"WARNING: {name} has {int(bad.sum())} non-finite values")

station.attrs = dict(regional.attrs)
station.attrs["source"] = os.path.realpath(source)
station.attrs["history"] = "cut to the station grid by 2b_make_glorys.py"

# --- 5. write it like the regional file: same dtypes, NetCDF3 like the model's other inputs
encoding = {}
for name in station.variables:
    # xh and yh are new here (the regional file has no such variables), so they keep their own dtype
    dtype = station[name].dtype if name in ("xh", "yh") else regional[name].dtype
    encoding[name] = {"dtype": dtype, "_FillValue": None}
station.to_netcdf(f"{folder}/glorys_ic_station.nc", format="NETCDF3_64BIT", encoding=encoding,
                  unlimited_dims=["time"])

with open(f"{folder}/build.log", "w") as f:
    f.write("\n".join(report) + "\n")
with open(f"{folder}/source.txt", "w") as f:
    f.write(os.path.realpath(source) + "\n")

# --- 6. check: the model expects a 4 x 4 file with the 75 levels of the regional one
check = xr.open_dataset(f"{folder}/glorys_ic_station.nc", decode_times=False)
assert (check.sizes["yh"], check.sizes["xh"]) == (4, 4), "GLORYS state is not 4 x 4"
assert check.sizes["zl"] == regional.sizes["zl"], "GLORYS state lost levels"
assert np.isfinite(check["temp"].values).all() and np.isfinite(check["salt"].values).all(), "non-finite temp or salt"

# --- 7. the model reads model/INPUT/glorys_ic_station.nc
if os.path.lexists("model/INPUT/glorys_ic_station.nc"):
    os.remove("model/INPUT/glorys_ic_station.nc")
os.symlink(f"glorys/{config['STATION']}/glorys_ic_station.nc", "model/INPUT/glorys_ic_station.nc")

print("\n".join(report))
print(f"Step 2b done: {folder}/glorys_ic_station.nc")
