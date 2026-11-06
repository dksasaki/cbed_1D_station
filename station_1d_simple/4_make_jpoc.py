#!/usr/bin/env python3
"""
Step 4 - ONLY for the biot_bioi executable: the long-term mean POC flux to the seafloor.

Reads   config.sh                   STATION, COBALT_DIR, YEAR0
        <COBALT_DIR>/*.cobalt_btm_<YEAR0>_*.nc   daily bottom fluxes
Writes  model/INPUT/cbed/<STATION>/fntot_btm_mean.nc   time mean of fntot_btm (mol N m-2 s-1), on the COBALT grid
        model/INPUT/fntot_btm_mean.nc     link to it (the name data_table uses)

The biot_bioi build computes CBED's decay rates and bio-mixing from this
field. It reads it through data_table: uncomment the 'cbed_jpoc_mean' line
there. data_override interpolates the regional field onto the station
(bilinear), as for porosity.
"""
import glob
import os
import sys

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
files = sorted(glob.glob(os.path.join(config["COBALT_DIR"], f"*.cobalt_btm_{config['YEAR0']}_*.nc")))
if not files:
    sys.exit(f"ERROR: no cobalt_btm files for {config['YEAR0']} in {config['COBALT_DIR']}")

# all daily records of the year, averaged (dask reads the files piece by piece)
ds = xr.open_mfdataset(files, combine="nested", concat_dim="time", decode_times=False,
                       data_vars="minimal", coords="minimal", compat="override")
n_records = ds.sizes["time"]
mean = ds["fntot_btm"].mean("time").fillna(0.0).load()          # land (NaN) -> 0
if (mean < 0).any():
    sys.exit("ERROR: negative mean fntot_btm")

# the layout data_override expects: fntot_btm(time=1, lat, lon)
flux = mean.rename({"yh": "lat", "xh": "lon"}).expand_dims(time=[0.0]).astype("f4")
flux.attrs = {"units": "mol m-2 s-1", "long_name": "time-mean total N sinking flux to the bottom"}
out = flux.to_dataset(name="fntot_btm")
out["time"].attrs = {"units": "days since 1993-01-01 00:00:00", "calendar": "noleap", "cartesian_axis": "T"}
out["lat"].attrs = {"units": "degrees_north", "cartesian_axis": "Y"}
out["lon"].attrs = {"units": "degrees_east", "cartesian_axis": "X"}
out.attrs = {"source": " ".join(files), "history": f"mean of {n_records} records by 4_make_jpoc.py"}
folder = f"model/INPUT/cbed/{config['STATION']}"
os.makedirs(folder, exist_ok=True)
out.to_netcdf(f"{folder}/fntot_btm_mean.nc", encoding={name: {"_FillValue": None} for name in out.variables})

# the model reads model/INPUT/fntot_btm_mean.nc (the name in data_table)
if os.path.lexists("model/INPUT/fntot_btm_mean.nc"):
    os.remove("model/INPUT/fntot_btm_mean.nc")
os.symlink(f"cbed/{config['STATION']}/fntot_btm_mean.nc", "model/INPUT/fntot_btm_mean.nc")

print(f"Step 4 done: {folder}/fntot_btm_mean.nc, mean of {n_records} records from {len(files)} files")
print("Remember: uncomment the 'cbed_jpoc_mean' line in model/data_table.")
