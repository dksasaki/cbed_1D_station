#!/usr/bin/env python3
"""
Step 3 - the nudging (sponge) files for the station.

Reads   config.sh               STATION, MODE, YEAR0, YEAR1, SPONGE_TAU, GLORYS_DIR, COBALT_DIR
        model/INPUT/ocean_hgrid.nc    the station grid from step 1
Writes  model/INPUT/sponge/<STATION>/
            sponge_ts.nc        temp, salt                         (GLORYS monthly means)
            sponge_bgc.nc       o2, no3, po4, sio4, dic, alk       (NEUS25 COBALT, averaged per month)
            sponge_damping.nc   Idamp = 1 / SPONGE_TAU
            build.log           which source column fed each cell, and the records used per month
            build.txt           mode, years, tau and date of this build
        model/INPUT/sponge_*.nc       links to the three files above

The months depend on the run mode:
  repeat      the 12 months of YEAR0; the file repeats every year ('modulo')
  sequential  every month of YEAR0..YEAR1, plus December before and January
              after (the mean of that calendar month), so the run stays inside

Each station cell takes the nearest wet column of each source.
Every month of the run years must have data, or this step stops.
"""
import datetime
import glob
import os
import sys

import cftime
import numpy as np
import xarray as xr

RHO_0 = 1035.0                  # kg m-3, as in MOM_input
FILL = np.float32(1.0e20)

# name in the sponge file <- name in the COBALT file, factor to mol kg-1
BGC_VARIABLES = {
    "o2":   ("o2",     1.0),
    "no3":  ("no3",    1.0),
    "po4":  ("po4",    1.0),
    "sio4": ("si",     1.0 / RHO_0),     # COBALT calls silicate 'si', in mol m-3
    "dic":  ("dissic", 1.0 / RHO_0),     # mol m-3
    "alk":  ("talk",   1.0 / RHO_0),     # mol m-3
}
MIN_RECORDS = 6                 # COBALT has about 8 four-day records per month


def read_config(path="config.sh"):
    """The KEY=value lines of config.sh, without comments and quotes."""
    config = {}
    for line in open(path):
        line = line.split("#")[0].strip()
        if "=" in line and not line.startswith("export"):
            key, value = line.split("=", 1)
            config[key.strip()] = value.strip().strip('"')
    return config


def nearest_wet_columns(src_lon, src_lat, wet, label):
    """For each station cell, the (j, i) of the nearest wet source column, as index arrays (y, x)."""
    wet_j, wet_i = np.nonzero(wet)
    coslat = np.cos(np.deg2rad(lat.mean()))
    pick_j = np.zeros(lon.shape, dtype=int)
    pick_i = np.zeros(lon.shape, dtype=int)
    for j in range(lon.shape[0]):
        for i in range(lon.shape[1]):
            dist2 = ((src_lon[wet_i] - lon[j, i]) * coslat) ** 2 + (src_lat[wet_j] - lat[j, i]) ** 2
            k = int(np.argmin(dist2))
            pick_j[j, i] = wet_j[k]
            pick_i[j, i] = wet_i[k]
            report.append(f"{label} cell ({i + 1},{j + 1}) <- (i={wet_i[k]}, j={wet_j[k]}) "
                          f"{src_lat[wet_j[k]]:8.3f}N {src_lon[wet_i[k]]:9.3f}E, {np.sqrt(dist2[k]) * 111.0:5.1f} km")
    return xr.DataArray(pick_j, dims=("y", "x")), xr.DataArray(pick_i, dims=("y", "x"))


def stop(message):
    sys.exit(f"ERROR: {message}")


config = read_config()
mode = config["MODE"]
year0 = int(config["YEAR0"])
year1 = year0 if mode == "repeat" else int(config["YEAR1"])
run_months = [(year, month) for year in range(year0, year1 + 1) for month in range(1, 13)]
folder = f"model/INPUT/sponge/{config['STATION']}"
os.makedirs(folder, exist_ok=True)
report = []

# --- the station cells: centres of the 4 x 4 grid (the odd points of the supergrid)
grid = xr.open_dataset("model/INPUT/ocean_hgrid.nc")
lon = grid["x"].values[1::2, 1::2]
lat = grid["y"].values[1::2, 1::2]


# =============================================================================
# 1. T and S from GLORYS: one file per month (YYYY-MM.nc), already monthly means
# =============================================================================

def glorys_file(year, month):
    return os.path.join(config["GLORYS_DIR"], f"{year}-{month:02d}.nc")

for year, month in run_months:
    if not os.path.exists(glorys_file(year, month)):
        stop(f"no GLORYS file {glorys_file(year, month)}")

first = xr.open_dataset(glorys_file(*run_months[0]))
glorys_wet = first["thetao"].isel(time=0, depth=0).notnull().values
glorys_j, glorys_i = nearest_wet_columns(first["longitude"].values, first["latitude"].values, glorys_wet, "GLORYS")
glorys_depth = first["depth"].values

temp, salt = [], []
for year, month in run_months:
    ds = xr.open_dataset(glorys_file(year, month))
    columns = ds.isel(time=0, latitude=glorys_j, longitude=glorys_i).drop_vars(["latitude", "longitude", "time"])
    temp.append(columns["thetao"].load())
    salt.append(columns["so"].load())


# =============================================================================
# 2. BGC from NEUS25 COBALT: <YYYYMM01>.cobalt_tracers_<YYYY>_<MM>.nc, 4-day means
# =============================================================================

def cobalt_file(year, month):
    # the prefix is the start of a 2-month chunk, so search for the suffix
    found = glob.glob(os.path.join(config["COBALT_DIR"], f"*.cobalt_tracers_{year}_{month:02d}.nc"))
    if not found:
        stop(f"no COBALT file for {year}-{month:02d} in {config['COBALT_DIR']}")
    return found[0]

first = xr.open_dataset(cobalt_file(*run_months[0]), decode_times=False)
cobalt_wet = first["o2"].isel(time=0, z_l=0).notnull().values
cobalt_j, cobalt_i = nearest_wet_columns(first["xh"].values, first["yh"].values, cobalt_wet, "COBALT")
cobalt_depth = first["z_l"].values

bgc = {name: [] for name in BGC_VARIABLES}
for year, month in run_months:
    ds = xr.open_dataset(cobalt_file(year, month), decode_times=False)

    # the date of each record: the middle of its averaging period
    middle = 0.5 * (ds["average_T1"].values + ds["average_T2"].values)
    dates = cftime.num2date(middle, ds["time"].attrs["units"], ds["time"].attrs.get("calendar", "julian"))
    use = np.array([(d.year, d.month) == (year, month) for d in dates])

    columns = {}
    for name, (cobalt_name, factor) in BGC_VARIABLES.items():
        columns[name] = ds[cobalt_name].isel(yh=cobalt_j, xh=cobalt_i).drop_vars(["yh", "xh"]).load() * factor
        # records that were never written are all zero or fill: do not use them
        never_written = ((columns[name] == 0) | columns[name].isnull()).all(dim=("z_l", "y", "x")).values
        use = use & ~never_written

    report.append(f"COBALT {year}-{month:02d}: {int(use.sum())} records used")
    if use.sum() < MIN_RECORDS:
        stop(f"COBALT {year}-{month:02d} has only {int(use.sum())} usable records (need {MIN_RECORDS})")
    for name in BGC_VARIABLES:
        bgc[name].append(columns[name].isel(time=use).mean("time"))


# =============================================================================
# 3. the time axis, as FMS reads it
# =============================================================================

if mode == "repeat":
    # middle of each month of a 365-day year; 'modulo' makes FMS repeat it every year
    days_in_month = np.array([31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31])
    days = np.cumsum(days_in_month) - days_in_month / 2.0
    time_attrs = {"units": "days since 0001-01-01 00:00:00", "calendar": "julian", "cartesian_axis": "T",
                  "long_name": "middle of climatological month", "modulo": " "}
    pad = False
else:
    # the real months, plus December before and January after
    months = [(year0 - 1, 12)] + run_months + [(year1 + 1, 1)]
    units = f"days since {year0 - 1}-01-01 00:00:00"
    days = cftime.date2num([cftime.datetime(y, m, 15, calendar="julian") for y, m in months], units, "julian")
    time_attrs = {"units": units, "calendar": "julian", "cartesian_axis": "T", "long_name": "middle of month"}
    pad = True


def monthly_series(profiles):
    """Stack the monthly profiles in time; in sequential mode add the two padding months."""
    if pad:
        months_of_year = np.array([m for _, m in run_months])
        december = xr.concat([profiles[k] for k in np.nonzero(months_of_year == 12)[0]], "time").mean("time")
        january = xr.concat([profiles[k] for k in np.nonzero(months_of_year == 1)[0]], "time").mean("time")
        profiles = [december] + profiles + [january]
    return xr.concat(profiles, dim="time")


time = xr.DataArray(np.asarray(days, dtype="f8"), dims="time", attrs=time_attrs)
station_xy = {"x": ("x", lon[0, :], {"units": "degrees_east", "cartesian_axis": "X"}),
              "y": ("y", lat[:, 0], {"units": "degrees_north", "cartesian_axis": "Y"})}
z_attrs = {"units": "m", "positive": "down", "cartesian_axis": "Z"}


# =============================================================================
# 4. write the three files (float32, fill 1e20, NetCDF3, time unlimited)
# =============================================================================

def write(ds, path):
    encoding = {name: {"dtype": "f4", "_FillValue": FILL, "missing_value": FILL} for name in ds.data_vars}
    encoding.update({name: {"_FillValue": None} for name in ds.coords})
    ds.to_netcdf(path, format="NETCDF3_64BIT_OFFSET", unlimited_dims=["time"], encoding=encoding)


sponge_ts = xr.Dataset({"temp": monthly_series(temp).assign_attrs(units="degC"),
                        "salt": monthly_series(salt).assign_attrs(units="psu")})
sponge_ts = sponge_ts.assign_coords(time=time, depth=("depth", glorys_depth, z_attrs), **station_xy)
sponge_ts.attrs = {"source": config["GLORYS_DIR"], "history": f"{mode} nudging file by 3_make_sponge.py"}
write(sponge_ts, f"{folder}/sponge_ts.nc")

sponge_bgc = xr.Dataset({name: monthly_series(bgc[name]).assign_attrs(units="mol kg-1") for name in BGC_VARIABLES})
sponge_bgc = sponge_bgc.assign_coords(time=time, z_l=("z_l", cobalt_depth, z_attrs), **station_xy)
sponge_bgc.attrs = {"source": config["COBALT_DIR"], "history": f"{mode} nudging file by 3_make_sponge.py"}
write(sponge_bgc, f"{folder}/sponge_bgc.nc")

tau = float(config["SPONGE_TAU"])
idamp = xr.DataArray(np.full(lon.shape, 1.0 / (tau * 86400.0)), dims=("y", "x"),
                     attrs={"units": "s-1", "long_name": f"inverse nudging timescale (tau = {tau:g} days)"})
damping = xr.Dataset({"Idamp": idamp}).assign_coords(**station_xy)
damping.to_netcdf(f"{folder}/sponge_damping.nc", format="NETCDF3_64BIT_OFFSET",
                  encoding={name: {"_FillValue": None} for name in damping.variables})

with open(f"{folder}/build.log", "w") as f:
    f.write("\n".join(report) + "\n")
with open(f"{folder}/build.txt", "w") as f:
    f.write(f"mode={mode} years={year0}-{year1} tau={tau:g}d ({datetime.date.today()})\n")

# the model reads the files from model/INPUT/
for name in ("sponge_ts.nc", "sponge_bgc.nc", "sponge_damping.nc"):
    if os.path.lexists(f"model/INPUT/{name}"):
        os.remove(f"model/INPUT/{name}")
    os.symlink(f"sponge/{config['STATION']}/{name}", f"model/INPUT/{name}")


# =============================================================================
# 5. check and summary
# =============================================================================

for path, ds in (("sponge_ts.nc", sponge_ts), ("sponge_bgc.nc", sponge_bgc)):
    for name, var in ds.data_vars.items():
        surface = var.isel({var.dims[1]: 0})
        if surface.isnull().all("time").any():
            stop(f"{path}: {name} has a column with no data")
        print(f"  {name:5s} surface {float(surface.min()):.4g} .. {float(surface.max()):.4g} {var.attrs['units']}")

print(f"Step 3 done: {folder}/sponge_ts.nc, sponge_bgc.nc, sponge_damping.nc ({mode} mode, tau {tau:g} days)")
