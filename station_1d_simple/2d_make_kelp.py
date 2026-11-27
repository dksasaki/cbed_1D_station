#!/usr/bin/env python3
"""
Step 2d - the kelp sources and sinks for the station.

Reads   config.sh                       STATION, DEPTH, MODE, YEAR0, YEAR1
        kelp.toml                       [source] and [sink]: rate, active windows, freq, depth
        model/INPUT/ocean_hgrid.nc      the station grid from step 1
        model/INPUT/vgrid_75_2m.nc      the vertical grid, linked by step 0
Writes  model/INPUT/kelp/<STATION>/mask_addition.nc    source, if enabled
        model/INPUT/kelp/<STATION>/mask_e_juptake.nc   sink, if enabled
        model/INPUT/kelp/<STATION>/build.log
        model/INPUT/mask_addition.nc, mask_e_juptake.nc   links to the files above

Why: the sinksource build of COBALT reads the kelp forcing through FMS
data_override (the kelp lines of model/data_table):

  source  mask_addition_t (z, y, x)        static; COBALT reads only the top level
          ndet_addition   (time, y, x)     mol N m-2 s-1 before the data_table scale,
                                           added to the bottom layer
  sink    mask_e_juptake  (z, y, x)        static
          e_juptake_no3   (time, z, y, x)  mol N kg-1 s-1 before the data_table scale

pdet/fedet and po4/fed read these same variables with Redfield-type scale factors.
A field with a time axis is interpolated in time, and the model stops if its
clock leaves the axis, so the axis spans every year the run simulates.
True 1D: the 16 cells are the same column, so every cell gets the same forcing.
The switches are do_external_source / do_external_sink in model/COBALT_input.
"""
import os
import tomllib

import numpy as np
import pandas as pd
import xarray as xr

FILL = 1.0e20
FILES = {"source": "mask_addition.nc", "sink": "mask_e_juptake.nc"}
ATTRS = {
    "mask_addition_t": {"long_name": "kelp detritus source mask", "units": "1"},
    "ndet_addition": {"long_name": "kelp N detritus flux to the bottom layer",
                      "units": "mol N m-2 s-1 / data_table scale"},
    "mask_e_juptake": {"long_name": "kelp nutrient uptake mask", "units": "1"},
    "e_juptake_no3": {"long_name": "kelp NO3 uptake rate",
                      "units": "mol N kg-1 s-1 / data_table scale"},
}


def read_config(path="config.sh"):
    """The KEY=value lines of config.sh, without comments and quotes."""
    config = {}
    for line in open(path):
        line = line.split("#")[0].strip()
        if "=" in line and not line.startswith("export"):
            key, value = line.split("=", 1)
            config[key.strip()] = value.strip().strip('"')
    return config


def load_grid(hgrid, vgrid):
    """Ones on the station's (z, y, x): cell centres of the supergrid, nominal layer centres [m]."""
    lon = xr.open_dataset(hgrid)["x"].values[1::2, 1::2]
    lat = xr.open_dataset(hgrid)["y"].values[1::2, 1::2]
    dz = xr.open_dataset(vgrid)["dz"].values
    z = xr.DataArray(np.cumsum(dz) - dz / 2, dims="z",
                     attrs={"units": "m", "long_name": "nominal layer centre depth",
                            "axis": "Z", "positive": "down"})
    return xr.DataArray(np.ones((dz.size, *lon.shape)), dims=("z", "y", "x"),
                        coords={"z": z,
                                "y": ("y", lat[:, 0], {"units": "degrees_north", "axis": "Y"}),
                                "x": ("x", lon[0, :], {"units": "degrees_east", "axis": "X"})})


def level_mask(z, depth, bottom):
    """1 on layers whose nominal centre lies in [top, bottom] and above the sea floor."""
    top, base = depth
    levels = (z >= top) & (z <= base) & (z < bottom)
    if not levels.any():
        raise ValueError(f"depth {depth} selects no layer above the bottom ({bottom} m)")
    return levels.astype(float)


def time_signal(times, active):
    """0/1 switch on the time axis: 1 inside any of the active windows."""
    on = np.zeros(times.size, dtype=bool)
    for start, end in active:
        if not times[0] <= pd.Timestamp(start) <= pd.Timestamp(end) <= times[-1]:
            raise ValueError(f"active window {start} .. {end} is outside the time axis "
                             f"{times[0]:%Y-%m-%d} .. {times[-1]:%Y-%m-%d}")
        on |= (times >= start) & (times <= end)
    return xr.DataArray(on.astype(float), coords={"time": times}, dims="time")


def source_dataset(cells, case, times, bottom):
    return xr.Dataset({
        "mask_addition_t": cells,
        "ndet_addition": case["rate"] * cells.isel(z=0, drop=True) * time_signal(times, case["active"]),
    })


def sink_dataset(cells, case, times, bottom):
    mask = cells * level_mask(cells.z, case["depth"], bottom)
    return xr.Dataset({
        "mask_e_juptake": mask,
        "e_juptake_no3": case["rate"] * mask * time_signal(times, case["active"]),
    })


def save(ds, path, units):
    """NETCDF3_CLASSIC with an unlimited time axis, as data_override expects."""
    fields = list(ds.data_vars)
    ds = ds.transpose("time", "z", "y", "x", missing_dims="ignore")
    ds = ds.assign(lon=ds.x, lat=ds.y)
    for v in fields:
        ds[v].attrs = {**ATTRS[v], "coordinates": "lat lon"}
    encoding = {v: {"_FillValue": None} for v in [*ds.coords, "lon", "lat"]}
    encoding |= {v: {"dtype": "float32", "_FillValue": FILL} for v in fields}
    encoding["time"] = {"units": units, "calendar": "gregorian", "dtype": "float64", "_FillValue": None}
    ds.to_netcdf(path, format="NETCDF3_CLASSIC", unlimited_dims=["time"], encoding=encoding)


def report(name, case, ds, path):
    """What was written, to check against kelp.toml."""
    mask, rate = ds.data_vars.values()
    levels = mask.z.where(mask.max(["y", "x"]) > 0, drop=True)
    active = rate.max([d for d in rate.dims if d != "time"]) > 0
    times = pd.DatetimeIndex(ds.time.values)
    return [f"{name}: {path}",
            f"  settings: {case}",
            f"  {int(mask.max('z').sum())} columns; {levels.size} levels, "
            f"centres {levels.values[0]:.1f} .. {levels.values[-1]:.1f} m",
            f"  time {times[0]:%Y-%m-%d} .. {times[-1]:%Y-%m-%d} ({case['freq']}): "
            f"{int(active.sum())} of {times.size} records active"]


BUILDERS = {"source": source_dataset, "sink": sink_dataset}

config = read_config()
with open("kelp.toml", "rb") as f:
    kelp = tomllib.load(f)
folder = f"model/INPUT/kelp/{config['STATION']}"
os.makedirs(folder, exist_ok=True)

cells = load_grid("model/INPUT/ocean_hgrid.nc", "model/INPUT/vgrid_75_2m.nc")
bottom = float(config["DEPTH"])
year0 = int(config["YEAR0"])
year1 = year0 if config["MODE"] == "repeat" else int(config["YEAR1"])   # as run.sh: repeat replays YEAR0
units = "days since 1993-01-01"

log = [f"STATION={config['STATION']} DEPTH={bottom} MODE={config['MODE']} years {year0}..{year1}"]
for name, build in BUILDERS.items():
    case = kelp[name]
    if not case["enabled"]:
        log.append(f"{name}: disabled")
        continue
    times = pd.date_range(f"{year0}-01-01", f"{year1 + 1}-01-01", freq=case["freq"])
    ds = build(cells, case, times, bottom)
    path = f"{folder}/{FILES[name]}"
    save(ds, path, units)
    log += report(name, case, ds, path)

    link = f"model/INPUT/{FILES[name]}"           # the path in model/data_table
    if os.path.lexists(link):
        os.remove(link)
    os.symlink(f"kelp/{config['STATION']}/{FILES[name]}", link)

with open(f"{folder}/build.log", "w") as f:
    f.write("\n".join(log) + "\n")
print("\n".join(log))
print(f"Step 2d done: {folder}/")
