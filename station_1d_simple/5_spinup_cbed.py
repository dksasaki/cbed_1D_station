#!/usr/bin/env python3
"""
Step 5 - the CBED initial state in equilibrium with THIS 1D column.

Reads   config.sh                     STATION, DEPTH, CBED_FORCING_RUN, CBED_TOOLS
        $CBED_FORCING_RUN/*.ocean_cobalt_btm.nc, *.ocean_cobalt_tracers_month_z.nc,
                          *.ocean_daily.nc, *.ocean_cbed_day.nc   one year of a 1D run
        $CBED_TOOLS/config.toml       [cbed] model, params, spinup (as for the regional solution)
        model/INPUT/cbed/<STATION>/generic_CBED.res.nc   the current CBED state (first guess)
Writes  model/INPUT/cbed/<STATION>/generic_CBED.res.nc   the new state (same layout)
        model/INPUT/cbed/<STATION>/generic_CBED.res.from_step2.nc   the step 2 state, kept once
        model/INPUT/cbed/<STATION>/build.log, source.txt

Why: step 2 copies a regional CBED solution, spun up under the regional bottom
forcing (other POC flux, O2, temperature, depth). The 1D column delivers a
different forcing, so CBED drifts for centuries (OM3). This step spins CBED up
under the 1D column's own forcing, with the same tool as the regional solution:
cbed2py's Newton-Krylov spin-up to the periodic (repeat-year) state, through the
functions of cbed_wrapper.py.

How: for each of the 4 x 4 cells, the 12 monthly means of the forcing year become
the periodic forcing (phase = mid-month), converted as generic_CBED.F90 does
(concentrations x Rho_0, TAlk from btm_alk, w from the sinking fluxes / (1 - por),
f.OM1-3 from DEPTH, porosity as the model reads it). The current state is the
first guess. The result is the periodic state at Jan 1.

Run with the python of $CBED_TOOLS/.pixi (rpy2, R, cbed2py), on a compute node:
    export PATH=$CBED_TOOLS/.pixi/envs/default/bin:$PATH
    python3 5_spinup_cbed.py [N_WORKERS]
"""
import glob
import os
import shutil
import sys
import time
import tomllib
from multiprocessing import Pool

import numpy as np
import xarray as xr

RHO_0 = 1035.0          # [kg m-3] as cobalt%Rho_0 in generic_CBED.F90


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
tools = config["CBED_TOOLS"]
sys.path.insert(0, os.path.join(tools, "scripts"))
import cbed_wrapper as cw                                  # noqa: E402  (needs the path above)
from cbed2py.spinup import newton_krylov_spinup            # noqa: E402

folder = f"model/INPUT/cbed/{config['STATION']}"
state_file = f"{folder}/generic_CBED.res.nc"
run = config["CBED_FORCING_RUN"]
n_workers = int(sys.argv[1]) if len(sys.argv) > 1 else 8


def one_file(pattern):
    files = glob.glob(os.path.join(run, pattern))
    assert len(files) == 1, f"expected one {pattern} in {run}, found {files}"
    return xr.open_dataset(files[0], decode_times=False)


# --- 1. one year of the 1D run: monthly bottom fields (time = 12 months)
btm = one_file("*.ocean_cobalt_btm.nc")
trz = one_file("*.ocean_cobalt_tracers_month_z.nc")
day = one_file("*.ocean_daily.nc")
cbd = one_file("*.ocean_cbed_day.nc")
assert btm.sizes["time"] == 12 and trz.sizes["time"] == 12, "the forcing run must be one year of monthly output"

# the bottom level of each column: the deepest level with a value
def bottom(da, zdim):
    k = da.isel(time=0, drop=True).notnull().cumsum(zdim).argmax(zdim)
    return da.isel({zdim: k})

nh4_btm = bottom(trz["nh4"], "z_l")                          # mol kg-1
salt_btm = bottom(day["salt"], "zl")                         # daily
porosity = cbd["cbed_por"].isel(time=0, cbedlayer_i=0)      # as the model reads it (data_table)

# --- 2. the forcing, in the variables and units cbed_wrapper expects
# cbed_wrapper multiplies O2, NO3, DIC, NH4 by 1e3; generic_CBED.F90 by Rho_0. Scale by Rho_0/1e3 here.
scale = RHO_0 / 1e3
phase = (np.arange(12) + 0.5) / 12
fn_other = ["fndet_btm", "fndi_btm", "fnmd_btm", "fnlg_btm"]
fp_other = ["fpdet_btm", "fpdi_btm", "fpmd_btm", "fplg_btm"]
fe_other = ["ffedet_btm", "ffedi_btm", "ffemd_btm", "ffelg_btm"]
cob = btm[sorted(set(fn_other + fp_other + fe_other + [
    "fntot_btm", "fptot_btm", "ffetot_btm", "fcadet_arag_btm", "fcadet_calc_btm",
    "fsidet_btm", "fsimd_btm", "fsilg_btm", "flithdet_btm", "btm_temp", "btm_alk"]))]
cob = cob.assign(btm_o2=btm["btm_o2"] * scale, btm_no3=btm["btm_no3"] * scale, btm_dic=btm["btm_dic"] * scale)
# the small-phytoplankton fluxes are not in the 1D output: the remainder of the totals (cbed_wrapper sums the parts)
cob["fnsm_btm"] = btm["fntot_btm"] - sum(btm[v] for v in fn_other)
cob["fpsm_btm"] = btm["fptot_btm"] - sum(btm[v] for v in fp_other)
cob["ffesm_btm"] = btm["ffetot_btm"] - sum(btm[v] for v in fe_other)
tr = xr.Dataset({"nh4": nh4_btm * scale, "talk": btm["btm_alk"] * RHO_0})   # TAlk [mM], as generic_CBED.F90

# time means: the point setup of cbed_wrapper.point_params (w, porosity, depth, f.OM1-3, S)
dscob = cob.mean("time")
dscob2 = tr.mean("time")
dsmom = xr.Dataset({"temp": btm["btm_temp"].mean("time"), "salt": salt_btm.mean("time")})
dsporo = xr.Dataset({"porosity": porosity})
dsdepth = xr.Dataset({"depth": xr.full_like(porosity, float(config["DEPTH"]))})

# monthly climatology: the periodic forcing of the Newton-Krylov spin-up
clim = lambda ds: ds.rename(time="phase").assign_coords(phase=phase)
clim_btm, clim_tr = cw.forcing_fields(clim(xr.Dataset({"fntot_btm": btm["fntot_btm"],
                                                       "btm_o2": cob["btm_o2"], "btm_no3": cob["btm_no3"],
                                                       "btm_dic": cob["btm_dic"]})),
                                      clim(tr),
                                      clim(xr.Dataset({"temp": btm["btm_temp"]})))
for ds in (dscob, dscob2, dsmom, dsporo, dsdepth, clim_btm, clim_tr):
    ds.load()

# --- 3. the spin-up settings ([cbed] of the regional solution's config.toml)
cw.CBED_CFG = cw.load_cbed_config(os.path.join(tools, "config.toml"))
assert cw.CBED_CFG["method"] == "newton_krylov", "config.toml [cbed] method must be newton_krylov"

# the first guess: the current state
current = xr.open_dataset(state_file, decode_times=False, mask_and_scale=False).load()
names = {s: f"cbed_{s.lower()}" for s in cw.STATE_NAMES}
ny, nx = porosity.shape


def spin_cell(cell):
    """Newton-Krylov spin-up of one cell, as cbed_wrapper.cbed_nk_wrapped, with a first guess."""
    j, i = cell
    t0 = time.perf_counter()
    frc = cw.point_forcing(clim_btm.isel(xh=i, yh=j), clim_tr.isel(xh=i, yh=j))
    params = dict(cw.CBED_CFG["params"])
    params.update(cw.point_params(dsmom, dscob, dscob2, dsporo, dsdepth, i, j))
    params.update({v: float(np.mean(frc[v])) for v in frc if v != "time"})
    spin = {"max_newton": 10, "verbose": False, **cw.CBED_CFG["spinup"]}
    rel = spin.pop("tol_imbalance_rel", None)
    if rel is not None and "tol_imbalance" not in spin:
        spin["tol_imbalance"] = rel * params["J.OM"]
    yini = np.concatenate([current[names[s]].values[:, j, i].astype(float) for s in cw.STATE_NAMES])
    y, hist, _ = newton_krylov_spinup(params, frc, yini=yini, **spin)
    h = hist[-1]
    diag = {"converged": bool(h["converged"]), "newton": h["newton"], "imbalance_rel": h["imbalance"] / params["J.OM"],
            "rms_G": h["rms_G"], "model_years": h["runs"] * spin.get("n_periods", 1),
            "wall_min": (time.perf_counter() - t0) / 60,
            "J.OM": params["J.OM"], "O2.w": params["O2.w"], "temp": params["temp"], "w": params["w"],
            "por": params["por.0"], "f.OM": (params["f.OM1"], params["f.OM2"], params["f.OM3"])}
    return j, i, y.reshape(len(cw.STATE_NAMES), -1), diag


# --- 4. all cells, in parallel
cells = [(j, i) for j in range(ny) for i in range(nx)]
print(f"spinning up {len(cells)} cells with {n_workers} workers "
      f"(cbed2py model '{cw.CBED_CFG['model']}', forcing {os.path.realpath(run)})", flush=True)
with Pool(n_workers, initializer=cw.init_worker) as pool:
    results = pool.map(spin_cell, cells)

# --- 5. the new state: the current file with the 9 states replaced and the flux accumulators zeroed
if not os.path.exists(f"{folder}/generic_CBED.res.from_step2.nc"):
    shutil.copy(state_file, f"{folder}/generic_CBED.res.from_step2.nc")
new = current.copy(deep=True)
report = [f"forcing run {os.path.realpath(run)}, RHO_0 {RHO_0}, depth {config['DEPTH']} m, "
          f"cbed2py model {cw.CBED_CFG['model']}, spinup {cw.CBED_CFG['spinup']}"]
for j, i, y, d in results:
    for k, s in enumerate(cw.STATE_NAMES):
        new[names[s]].values[:, j, i] = y[k]
    report.append(f"cell ({i + 1},{j + 1}) converged={d['converged']} newton={d['newton']} "
                  f"imbalance={100 * d['imbalance_rel']:+.3f}% of J.OM rms_G={d['rms_G']:.1e} "
                  f"model_years={d['model_years']} wall={d['wall_min']:.1f} min | J.OM={d['J.OM']:.1f} "
                  f"O2.w={d['O2.w']:.4f} temp={d['temp']:.2f} w={d['w']:.4f} por={d['por']:.3f} "
                  f"f.OM={'/'.join(f'{f:.3f}' for f in d['f.OM'])}")
for name in new.data_vars:
    if name.endswith("_acc"):
        new[name].values[:] = 0
new.attrs["history"] = f"CBED periodic state under {os.path.realpath(run)}, by 5_spinup_cbed.py"

# --- 6. write it like the current file: same dtypes and fill values, NetCDF3
encoding = {name: {"dtype": current[name].dtype, "_FillValue": current[name].attrs.get("_FillValue")}
            for name in current.variables}
for name in new.variables:
    new[name].attrs.pop("_FillValue", None)
tmp = f"{state_file}.tmp"
new.to_netcdf(tmp, format="NETCDF3_64BIT", encoding=encoding)
current.close()
os.replace(tmp, state_file)

with open(f"{folder}/build.log", "w") as f:
    f.write("\n".join(report) + "\n")
with open(f"{folder}/source.txt", "w") as f:
    f.write(f"5_spinup_cbed.py: forcing {os.path.realpath(run)}; first guess and layout from the previous state\n")

# --- 7. check
check = xr.open_dataset(state_file, decode_times=False)
assert (check.sizes["y"], check.sizes["x"]) == (ny, nx) and "lev" in check.dims, "wrong layout"
for s in cw.STATE_NAMES:
    assert np.isfinite(check[names[s]].values).all(), f"{names[s]} has non-finite values"
print("\n".join(report))
n_bad = sum(not d["converged"] for *_, d in results)
print(f"Step 5 done: {state_file}  ({len(results) - n_bad} of {len(results)} cells converged)")
