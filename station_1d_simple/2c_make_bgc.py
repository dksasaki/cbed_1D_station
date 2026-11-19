#!/usr/bin/env python3
"""
Step 2c - the COBALT tracer initial state for the station.

Reads   config.sh                      STATION, IC_DIR
        $IC_DIR/bgc_woa_esper_ics_1993_2023-04_update2.nc   the regional tracer state (NWA25 grid, 396 x 430)
        $IC_DIR/ocean_hgrid.nc, ocean_topog.nc   the regional grid that file sits on
        model/INPUT/ocean_hgrid.nc     the station grid from step 1
Writes  model/INPUT/bgc/<STATION>/bgc_ic_station.nc
        model/INPUT/bgc/<STATION>/build.log   which regional cell fed each station cell
        model/INPUT/bgc/<STATION>/source.txt  the regional file used
        model/INPUT/bgc_ic_station.nc         link to the state above

Why: field_table makes MOM6 read every tracer's *_src_file with
MOM_initialize_tracer_from_Z (enforce_src_info = t). The regional file declares
_FillValue = NaN for all its tracers, and MOM6 tests "is this point missing?" with
abs(x - missing) > abs(roundoff*missing). With missing = NaN that is never true,
so every point is treated as missing, the interpolated field is all NaN, and the
run stops with "NaN in input field of reproducing_EFP_sum". The station file is
cut from the regional one and declares a finite _FillValue instead.

How: both grids are rectilinear, so each station column and row picks its nearest
regional one with .sel(method="nearest"). The whole water column (all levels) is
kept. A level without a value takes the value of the level above it, so a column
never has a gap; the regional file has none today, so this changes nothing now.
"""
import os

import numpy as np
import xarray as xr

FILL = 1.0e20      # a finite fill value; after the fill below no point carries it


def read_config(path="config.sh"):
    """The KEY=value lines of config.sh, without comments and quotes."""
    config = {}
    for line in open(path):
        line = line.split("#")[0].strip()
        if "=" in line and not line.startswith("export"):
            key, value = line.split("=", 1)
            config[key.strip()] = value.strip().strip('"')
    return config


def fill_down(ds):
    """Fill each missing (NaN) level with the level above it, down the water column (zl).
    The same as ds.ffill("zl"), which needs bottleneck; this needs only xarray."""
    levels = [ds.isel(zl=0, drop=True)]        # drop=True: the level's depth would clash in fillna; it is added back in step 4
    for k in range(1, ds.sizes["zl"]):
        levels.append(ds.isel(zl=k, drop=True).fillna(levels[-1]))
    return xr.concat(levels, dim="zl")


def rectilinear(hgrid):
    """The 1D longitudes and latitudes of the cell centres of a rectilinear supergrid."""
    x = hgrid["x"].values[1::2, 1::2]
    y = hgrid["y"].values[1::2, 1::2]
    assert np.allclose(x, x[0:1, :]) and np.allclose(y, y[:, 0:1]), "grid is not rectilinear"
    return x[0, :], y[:, 0]


config = read_config()
source = os.path.join(config["IC_DIR"], "bgc_woa_esper_ics_1993_2023-04_update2.nc")
folder = f"model/INPUT/bgc/{config['STATION']}"
os.makedirs(folder, exist_ok=True)

# --- 1. the station columns and rows: centres of the 4 x 4 grid (the odd points of the supergrid)
lon, lat = rectilinear(xr.open_dataset("model/INPUT/ocean_hgrid.nc"))

# --- 2. the regional solution; mask_and_scale=False keeps the numbers exactly as they are in the file
regional = xr.open_dataset(source, decode_times=False, mask_and_scale=False)
regional_lon, regional_lat = rectilinear(xr.open_dataset(os.path.join(config["IC_DIR"], "ocean_hgrid.nc")))
assert np.allclose(regional["xh"], regional_lon) and np.allclose(regional["yh"], regional_lat), \
    f"{source} is not on the grid of {config['IC_DIR']}/ocean_hgrid.nc"

# the regional depth, on the same coordinates, to make sure the station cells are ocean
depth = xr.DataArray(xr.open_dataset(os.path.join(config["IC_DIR"], "ocean_topog.nc"))["depth"].values,
                     dims=("yh", "xh"), coords={"yh": regional["yh"], "xh": regional["xh"]})

# --- 3. cut: the nearest regional column and row of every station column and row, all levels
fields = [name for name in regional.data_vars if regional[name].dims == ("Time", "zl", "yh", "xh")]
cut = regional[fields].sel(xh=lon, yh=lat, method="nearest")
depth_cut = depth.sel(xh=lon, yh=lat, method="nearest")
assert bool((depth_cut > 0).all()), "a station cell falls on a regional land cell"

xi = regional.get_index("xh").get_indexer(cut["xh"].values)
yi = regional.get_index("yh").get_indexer(cut["yh"].values)
report = []
for j in range(len(lat)):
    for i in range(len(lon)):
        coslat = np.cos(np.deg2rad(lat[j]))
        km = 111.0 * np.hypot((cut["xh"].values[i] - lon[i]) * coslat, cut["yh"].values[j] - lat[j])
        report.append(f"cell ({i + 1},{j + 1}) {lat[j]:8.3f}N {lon[i]:9.3f}E <- regional "
                      f"(i={xi[i]}, j={yi[j]}) {cut['yh'].values[j]:8.3f}N {cut['xh'].values[i]:9.3f}E, "
                      f"depth {float(depth_cut[j, i]):6.1f} m, {km:5.1f} km")

# --- 4. no gaps: a non-finite level takes the value of the level above it
with xr.set_options(keep_attrs=True):
    gaps = {name: int((~np.isfinite(cut[name])).sum()) for name in fields}
    station = fill_down(cut.where(np.isfinite(cut)))
for name, n in gaps.items():
    if n:
        report.append(f"{name}: {n} missing values filled from the level above")
    if int((~np.isfinite(station[name])).sum()):
        raise SystemExit(f"{name}: a column has no value at its top level to fill from; stopping")
    # the declared fill value moves to the encoding, and becomes finite
    station[name].attrs.pop("_FillValue", None)
    station[name].attrs.pop("missing_value", None)

station = station[fields]
station = station.assign_coords(zl=regional["zl"], Time=regional["Time"])
station = station.assign_coords(xh=("xh", lon, {"long_name": "h point longitude", "units": "degrees_east"}),
                                yh=("yh", lat, {"long_name": "h point latitude", "units": "degrees_north"}))
station = station.transpose("Time", "zl", "yh", "xh")

station.attrs = dict(regional.attrs)
station.attrs["source"] = os.path.realpath(source)
station.attrs["history"] = f"cut to the station grid by 2c_make_bgc.py, _FillValue {FILL:g} instead of NaN"

# --- 5. write it like the regional file: same dtypes, NetCDF3 like the model's other inputs
encoding = {}
for name in station.variables:
    dtype = station[name].dtype if name in ("xh", "yh") else regional[name].dtype
    encoding[name] = {"dtype": dtype, "_FillValue": FILL if name in fields else None}
unlimited = [d for d in regional.encoding.get("unlimited_dims", []) if d in station.dims]
station.to_netcdf(f"{folder}/bgc_ic_station.nc", format="NETCDF3_64BIT", encoding=encoding,
                  unlimited_dims=unlimited)

with open(f"{folder}/build.log", "w") as f:
    f.write("\n".join(report) + "\n")
with open(f"{folder}/source.txt", "w") as f:
    f.write(os.path.realpath(source) + "\n")

# --- 6. check: a 4 x 4 file with the same tracers and levels, finite values, finite fill value, same numbers
check = xr.open_dataset(f"{folder}/bgc_ic_station.nc", decode_times=False, mask_and_scale=False)
assert (check.sizes["yh"], check.sizes["xh"]) == (len(lat), len(lon)), "BGC state is not 4 x 4"
assert check.sizes["zl"] == regional.sizes["zl"], "BGC state lost levels"
assert [n for n in check.data_vars if check[n].ndim == 4] == fields, "BGC state lost tracers"
for name in fields:
    assert bool(np.isfinite(check[name]).all()), f"{name} has non-finite values"
    assert np.isfinite(check[name].attrs["_FillValue"]), f"{name} still has a non-finite _FillValue"   # mask_and_scale=False: it is an attribute
    if not gaps[name]:     # no gap was filled, so the values are exactly the regional ones
        assert check[name].variable.equals(cut[name].variable), f"{name} changed"

# --- 7. the model reads model/INPUT/bgc_ic_station.nc (field_table points to it)
if os.path.lexists("model/INPUT/bgc_ic_station.nc"):
    os.remove("model/INPUT/bgc_ic_station.nc")
os.symlink(f"bgc/{config['STATION']}/bgc_ic_station.nc", "model/INPUT/bgc_ic_station.nc")

print("\n".join(report))
print(f"Step 2c done: {folder}/bgc_ic_station.nc ({len(fields)} tracers)")
