#!/usr/bin/env python3
"""
Build the 3-D restoring ("sponge") inputs for one station grid.

    python3 make_sponge.py <griddir> [timescale_days]
    e.g. python3 make_sponge.py INPUT/grids/BATS 90

Writes three files into <griddir>, all on the 4x4 model grid so MOM6 can read
them with SPONGE_DATA_ONGRID = True:

  sponge_damping.nc     Idamp(yh,xh): the restoring rate, 1/(timescale) [s-1],
                        uniform over the column (default timescale 90 days).
                        MOM6 applies this one rate to T, S and every COBALT
                        tracer that is restored.
  sponge_state_woa13.nc ptemp_an, s_an (time,depth,yh,xh): WOA13 decav
                        monthly potential temperature [degC] and salinity.
  sponge_bgc.nc         no3, po4, sio4, dic, alk (time,depth,yh,xh) [mol kg-1]:
                        WOA13 annual nutrients and GLODAPv2 modern DIC (TCO2)
                        and alkalinity, repeated for 12 months.

Each target comes from the same global file, and is converted the same way,
as the corresponding initial condition (MOM_input for T/S, field_table for the
tracers). The profile is bilinear in the horizontal at the station centre,
renormalised over the source points that have data at each level. Below the
deepest value the last value is carried down, so the files have no missing
data. The one profile is copied into every cell, keeping all 16 columns
identical, as Z_INIT_HOMOGENIZE and HOMOGENIZE_FORCINGS do for the initial
state and the forcing.

setup_station.sh runs this automatically; run it by hand to change the
timescale for a station that is already built.
"""
import os
import sys

import netCDF4 as nc
import numpy as np

here = os.path.dirname(os.path.abspath(__file__))
INPUT = os.path.join(here, "INPUT")
GLODAP = os.path.join(INPUT, "GLODAPv2.2016b.oi-filled.20180322.nc")

# Physical targets: output name -> (source file, source variable).
TS = {
    "ptemp_an": (os.path.join(INPUT, "woa13_decav_ptemp_monthly_fulldepth_01.nc"), "ptemp_an"),
    "s_an": (os.path.join(INPUT, "woa13_decav_s_monthly_fulldepth_01.nc"), "s_an"),
}
TS_UNITS = {"ptemp_an": "degC", "s_an": "psu"}

# COBALT targets: tracer name -> (source file, source variable, factor to
# mol kg-1). The factors are those generic_tracer_utils applies to the
# field_table initial conditions: micromoles_per_liter -> 1/1035e3,
# micromoles_per_kg -> 1e-6.
BGC = {
    "no3": (os.path.join(INPUT, "woa13_all_n_annual_01.nc"), "n_an", 1.0 / 1035.0e3),
    "po4": (os.path.join(INPUT, "woa13_all_p_annual_01.nc"), "p_an", 1.0 / 1035.0e3),
    "sio4": (os.path.join(INPUT, "woa13_all_i_annual_01.nc"), "i_an", 1.0 / 1035.0e3),
    "dic": (GLODAP, "TCO2", 1.0e-6),
    "alk": (GLODAP, "TAlk", 1.0e-6),
}


def station_centre(hgrid):
    with nc.Dataset(hgrid) as d:
        x = np.asarray(d["x"][1::2, 1::2])  # tracer points of the supergrid
        y = np.asarray(d["y"][1::2, 1::2])
    return x[0, :], y[:, 0], float(x.mean()), float(y.mean())


def coord(d, *names):
    for n in names:
        if n in d.variables:
            return np.asarray(d[n][:])
    raise KeyError(names)


def profile(path, var, lon0, lat0):
    """(time, depth) profile of var at (lon0, lat0), and the file's depths."""
    d = nc.Dataset(path)
    lon = coord(d, "lon", "longitude")
    lat = coord(d, "lat", "latitude")
    lon0 = (lon0 - lon[0]) % 360.0 + lon[0]  # same convention as the file

    # The 2x2 source cell centres around the station, and their bilinear weights.
    i0 = int(np.searchsorted(lon, lon0) - 1) % lon.size
    i1 = (i0 + 1) % lon.size
    j0 = int(np.clip(np.searchsorted(lat, lat0) - 1, 0, lat.size - 2))
    j1 = j0 + 1
    fx = ((lon0 - lon[i0]) % 360.0) / ((lon[i1] - lon[i0]) % 360.0)
    fy = (lat0 - lat[j0]) / (lat[j1] - lat[j0])
    pts = [(j0, i0, (1 - fx) * (1 - fy)), (j0, i1, fx * (1 - fy)),
           (j1, i0, (1 - fx) * fy), (j1, i1, fx * fy)]

    nt, nz = d[var].shape[:2]
    num = np.zeros((nt, nz))
    den = np.zeros((nt, nz))
    for j, i, w in pts:
        col = d[var][:, :, j, i]  # masked where the source has no data
        ok = ~np.ma.getmaskarray(col)
        num += np.where(ok, w * np.ma.getdata(col), 0.0)
        den += np.where(ok, w, 0.0)

    if not (den[:, 0] > 0).all():
        # All four surrounding source cells are land (common at coastal
        # stations on a 1-degree atlas). Fall back to the nearest column with
        # data in a 5x5-degree neighbourhood; MOM6's own initialisation instead
        # extrapolates horizontally into land, so the two can differ a little.
        jj = np.arange(max(j0 - 2, 0), min(j0 + 4, lat.size))
        ii = np.arange(i0 - 2, i0 + 4) % lon.size
        sfc = d[var][0, 0, jj, ii]
        if np.ma.getmaskarray(sfc).all():
            sys.exit(f"ERROR: no {var} data in {os.path.basename(path)} within "
                     f"~3 deg of ({lat0:.3f}, {lon0:.3f}).")
        dlon = (lon[ii][None, :] - lon0 + 180.0) % 360.0 - 180.0
        dist = np.hypot(dlon * np.cos(np.radians(lat0)), lat[jj][:, None] - lat0)
        dist = np.where(np.ma.getmaskarray(sfc), np.inf, dist)
        jn, inn = np.unravel_index(np.argmin(dist), dist.shape)
        j, i = jj[jn], ii[inn]
        print(f"  WARNING: {os.path.basename(path)} is land around the station; "
              f"{var} uses the nearest ocean column at ({lat[j]:.1f}, {lon[i]:.1f}), "
              f"~{dist[jn, inn] * 111:.0f} km away")
        col = d[var][:, :, j, i]
        ok = ~np.ma.getmaskarray(col)
        num = np.where(ok, np.ma.getdata(col), 0.0)
        den = ok.astype(float)

    prof = np.full((nt, nz), np.nan)
    np.divide(num, den, out=prof, where=den > 0)
    for k in range(1, nz):  # carry the deepest value down
        prof[:, k] = np.where(np.isnan(prof[:, k]), prof[:, k - 1], prof[:, k])
    depth = np.asarray(d["depth"][:])
    d.close()
    return prof, depth


def write_state(path, fields, units, time, depth, xh, yh, source):
    """fields: name -> (12, depth) profile, written to every cell."""
    ny, nx = yh.size, xh.size
    with nc.Dataset(path, "w") as o:
        o.createDimension("time", None)
        o.createDimension("depth", depth.size)
        o.createDimension("yh", ny)
        o.createDimension("xh", nx)
        t = o.createVariable("time", "f8", ("time",))
        t[:] = time[:]
        t.units, t.calendar = time.units, time.calendar
        t.cartesian_axis, t.modulo = "T", " "
        z = o.createVariable("depth", "f8", ("depth",))
        z[:] = depth
        z.units, z.positive, z.cartesian_axis = "m", "down", "Z"
        for name, vals, ax in (("xh", xh, "X"), ("yh", yh, "Y")):
            c = o.createVariable(name, "f8", (name,))
            c[:] = vals
            c.cartesian_axis = ax
        o.source = source
        for name, prof in fields.items():
            v = o.createVariable(name, "f4", ("time", "depth", "yh", "xh"))
            v[:] = np.broadcast_to(prof[:, :, None, None], (time.size, depth.size, ny, nx))
            v.units = units[name]


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    griddir = sys.argv[1]
    days = float(sys.argv[2]) if len(sys.argv) == 3 else 90.0
    xh, yh, lon0, lat0 = station_centre(os.path.join(griddir, "ocean_hgrid.nc"))
    where = f"bilinear at ({lat0:.4f}N, {lon0:.4f}E), homogenised over the grid"

    # Damping rate
    with nc.Dataset(os.path.join(griddir, "sponge_damping.nc"), "w") as o:
        o.createDimension("xh", xh.size)
        o.createDimension("yh", yh.size)
        o.createVariable("xh", "f8", ("xh",))[:] = xh
        o.createVariable("yh", "f8", ("yh",))[:] = yh
        o["xh"].units, o["xh"].axis = "degrees_east", "X"
        o["yh"].units, o["yh"].axis = "degrees_north", "Y"
        v = o.createVariable("Idamp", "f4", ("yh", "xh"))
        v[:] = 1.0 / (days * 86400.0)
        v.units = "s-1"
        v.long_name = f"sponge restoring rate (1/{days:g} days)"
        o.restoring_timescale_days = days

    # T/S target: monthly, on the WOA depths. Its time axis is reused below.
    ts = {}
    for name, (path, var) in TS.items():
        ts[name], depth = profile(path, var, lon0, lat0)
    with nc.Dataset(TS["ptemp_an"][0]) as src:
        write_state(os.path.join(griddir, "sponge_state_woa13.nc"), ts, TS_UNITS,
                    src["time"], depth, xh, yh, "WOA13 decav monthly climatology, " + where)

        # BGC target: annual sources, put on the WOA depths (GLODAP's 33 levels
        # are interpolated linearly) and repeated for each of the 12 months.
        bgc = {}
        for name, (path, var, factor) in BGC.items():
            prof, z = profile(path, var, lon0, lat0)
            prof = np.interp(depth, z, prof[0]) * factor
            bgc[name] = np.broadcast_to(prof, (src["time"].size, depth.size))
        write_state(os.path.join(griddir, "sponge_bgc.nc"), bgc,
                    {n: "mol kg-1" for n in bgc}, src["time"], depth, xh, yh,
                    "WOA13 annual no3/po4/sio4, GLODAPv2.2016b TCO2/TAlk, " + where)

    print(f"Sponge inputs written to {griddir}: restoring toward WOA13/GLODAPv2 at "
          f"({lat0:.3f}, {lon0:.3f}) with a {days:g}-day timescale")
    print(f"  SST {np.nanmin(ts['ptemp_an'][:, 0]):.2f} to {np.nanmax(ts['ptemp_an'][:, 0]):.2f} C; "
          f"surface no3 {bgc['no3'][0, 0] * 1e6:.2f}, dic {bgc['dic'][0, 0] * 1e6:.0f}, "
          f"alk {bgc['alk'][0, 0] * 1e6:.0f} umol/kg; "
          f"1000 m no3 {np.interp(1000, depth, bgc['no3'][0]) * 1e6:.1f} umol/kg")


if __name__ == "__main__":
    main()
