#!/usr/bin/env python3
"""
Step 5 - the CBED initial state in equilibrium with THIS 1D column.

Reads   config.sh                     STATION, DEPTH, CBED_FORCING_RUN, CBED_TOOLS
        $CBED_FORCING_RUN/*.ocean_cobalt_btm.nc, *.ocean_cobalt_tracers_month_z.nc,
                          *.ocean_daily.nc, *.ocean_cbed_day.nc   one year of a 1D run
        cbed_spinup.toml              [cbed] model, params, spinup: the [cbed] part of $CBED_TOOLS/config.toml
                                      (as for the regional solution), copied here so the experiment keeps its settings
        $CBED_TOOLS/scripts/cbed_wrapper.py   the point setup (forcing, w, porosity, f.OM1-3), used as is
        model/INPUT/cbed/<STATION>/generic_CBED.res.nc   the current CBED state (file layout only)
Writes  model/INPUT/cbed/<STATION>/generic_CBED.res.nc   the new state (same layout)
        model/INPUT/cbed/<STATION>/generic_CBED.res.from_step2.nc   the step 2 state, kept once
        model/INPUT/cbed/<STATION>/build.log, source.txt

Why: step 2 copies a regional CBED solution, spun up under the regional bottom
forcing (other POC flux, O2, temperature, depth). The 1D column delivers a
different forcing, so CBED drifts for centuries (OM3). This step spins CBED up
under the 1D column's own forcing, with the same tool as the regional solution:
cbed2py's Newton-Krylov spin-up to the periodic (repeat-year) state, through the
functions of cbed_wrapper.py.

How: the 12 monthly means of the forcing year become the periodic forcing
(phase = mid-month), converted as generic_CBED.F90 does (concentrations x Rho_0,
TAlk from btm_alk, w from the sinking fluxes / (1 - por), f.OM1-3 from DEPTH,
porosity as the model reads it). The result is the periodic state at Jan 1.
True 1D: the 16 cells are the same column, so ONE cell (1,1) is spun up and
copied into all 16 (the cells' forcing differs only through the atmosphere,
~0.2% in J.OM).
No first guess (yini=None), as cbed_wrapper.cbed_nk_wrapped for the regional
solution: starting from the current state stalled at an OM imbalance of
-0.15% of J.OM and ran to max_newton (10 steps, ~480 model years per cell);
from cbed2py's own start one cell converged in 5 steps (145 model years, ~5 min).

Run with the python of $CBED_TOOLS/.pixi (rpy2, R, cbed2py), on a compute node:
    export PATH=$CBED_TOOLS/.pixi/envs/default/bin:$PATH
    export PYTHONPATH=$CBED_TOOLS/scripts          # for "import cbed_wrapper"
    python3 5_spinup_cbed.py
"""
import glob
import os
import shutil
import time

import numpy as np
import xarray as xr

import cbed_wrapper as cw        # $CBED_TOOLS/scripts, on PYTHONPATH (see "Run with" above)

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

folder = f"model/INPUT/cbed/{config['STATION']}"
state_file = f"{folder}/generic_CBED.res.nc"
run = config["CBED_FORCING_RUN"]


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


def bottom(da, zdim):
    """The bottom level of each column: the deepest level with a value"""
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
def clim(dataset):
    """12 monthly means -> the periodic forcing, on the phases (mid-month) of the year"""
    return dataset.rename(time="phase").assign_coords(phase=phase)


clim_btm, clim_tr = cw.forcing_fields(clim(xr.Dataset({"fntot_btm": btm["fntot_btm"],
                                                       "btm_o2": cob["btm_o2"], "btm_no3": cob["btm_no3"],
                                                       "btm_dic": cob["btm_dic"]})),
                                      clim(tr),
                                      clim(xr.Dataset({"temp": btm["btm_temp"]})))
for ds in (dscob, dscob2, dsmom, dsporo, dsdepth, clim_btm, clim_tr):
    ds.load()

# --- 3. the spin-up settings: cbed_spinup.toml, the [cbed] part of $CBED_TOOLS/config.toml copied here
cw.CBED_CFG = cw.load_cbed_config("cbed_spinup.toml")
assert cw.CBED_CFG["method"] == "newton_krylov", "cbed_spinup.toml [cbed] method must be newton_krylov"

# the current state: only its layout (dimensions, other variables) is kept
current = xr.open_dataset(state_file, decode_times=False, mask_and_scale=False).load()
variable_of = {state: f"cbed_{state.lower()}" for state in cw.STATE_NAMES}
ny, nx = porosity.shape

# --- 4. one cell (true 1D: all 16 cells are the same column)
CELL_J, CELL_I = 0, 0
print(f"spinning up cell (1,1) for all {ny * nx} cells "
      f"(cbed2py model '{cw.CBED_CFG['model']}', forcing {os.path.realpath(run)})", flush=True)
cw.init_worker()
start = time.perf_counter()
cell, diag = cw.cbed_nk_wrapped(dsmom, dscob, dscob2, dsporo, dsdepth, clim_btm, clim_tr, CELL_I, CELL_J, 0)
wall_min = (time.perf_counter() - start) / 60
column = {state: cell[state].values[:, 0] for state in cw.STATE_NAMES}     # 20 layers of each state
params = cw.point_params(dsmom, dscob, dscob2, dsporo, dsdepth, CELL_I, CELL_J)    # for the report
converged = diag["status"] == 1

# --- 5. the new state: the current file with the 9 states replaced and the flux accumulators zeroed
step2_copy = f"{folder}/generic_CBED.res.from_step2.nc"
if not os.path.exists(step2_copy):
    shutil.copy(state_file, step2_copy)
new = current.copy(deep=True)
for state in cw.STATE_NAMES:
    new[variable_of[state]].values[:] = column[state][:, None, None]      # the same column in every cell
for name in new.data_vars:
    if name.endswith("_acc"):
        new[name].values[:] = 0
new.attrs["history"] = f"CBED periodic state under {os.path.realpath(run)}, by 5_spinup_cbed.py"

report = [
    f"forcing run {os.path.realpath(run)}, RHO_0 {RHO_0}, depth {config['DEPTH']} m, "
    f"cbed2py model {cw.CBED_CFG['model']}, spinup {cw.CBED_CFG['spinup']}",
    f"cell (1,1) converged={converged} newton={diag['newton_steps']} "
    f"imbalance={100 * diag['imbalance_rel']:+.3f}% of J.OM rms_G={diag['rms_G']:.1e} "
    f"model_years={diag['model_years']:.0f} wall={wall_min:.1f} min | J.OM={params['J.OM']:.1f} "
    f"O2.w={params['O2.w']:.4f} temp={params['temp']:.2f} w={params['w']:.4f} por={params['por.0']:.3f} "
    f"f.OM={params['f.OM1']:.3f}/{params['f.OM2']:.3f}/{params['f.OM3']:.3f}",
]

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
    f.write(f"5_spinup_cbed.py: forcing {os.path.realpath(run)}; no first guess (cbed2py's own start); "
            f"file layout from the previous state; settings from cbed_spinup.toml\n")

# --- 7. check
check = xr.open_dataset(state_file, decode_times=False)
assert (check.sizes["y"], check.sizes["x"]) == (ny, nx) and "lev" in check.dims, "wrong layout"
for state in cw.STATE_NAMES:
    assert np.isfinite(check[variable_of[state]].values).all(), f"{variable_of[state]} has non-finite values"
print("\n".join(report))
print(f"Step 5 done: {state_file}  (cell (1,1) {'converged' if converged else 'NOT converged'}, "
      f"copied to all {ny * nx} cells)")
