# TODO — OM4.single_column.COBALT.station

## Refactoring the station setup

- [ ] **One config file per station** (TOML or YAML) holding name, lat/lon, depth, the CBED source, sponge sources and variable names, period and tau. This becomes the record of how each station was built.
- [ ] **A small shared Python module** for the steps the three scripts share: `station_grid()`, `map_columns()` (nearest wet column, with xESMF as an option later) and `write_ongrid()` (format, fill values, axis names).
- [ ] **One command that reads the config** and builds the grid, the CBED state and the sponge files, keeping the per-station folders and the symlink activation.
- [ ] **Run it in the pixi environment** instead of the system anaconda, which has the NumPy 1/2 conflict.
- [ ] **Write the station's MOM6 parameters to a generated file** (`INPUT/station/<name>/MOM_override_station`) and add it to `parameter_filename` in `input.nml`. Remember `#override` for parameters set in more than one file.
- [ ] **Check each build against what the model expects:**
  - grid is NI x NJ;
  - CBED layer axis is named `lev`;
  - `modulo` is on the climatology time axis;
  - units are mol kg-1 for BGC;
  - no columns are all fill values.
- [ ] **Look at CEFI `tools/sponge/` and `tools/initial/`** (`write_nudging_data.py`, `write_damping.py`, the YAML configs) and follow their approach, or contribute a station option back.
- [ ] **Write down the FMS/MOM6 traps** (see below), so they're recorded somewhere other than in the code.

## Still to do

- [ ] Fix the `'INPUT'/,` typo in `input.nml_1yr` (`restart_input_dir = 'INPUT/',`). Until then MOM6 stops with "There must be at least 1 valid entry in input_filename".
- [ ] Rebuild the GofME grid with the average depth: `./setup_station.sh GofME 43.9838 -67.1743 161.5` (the current topography is a flat 4000 m).
- [ ] Decide which `diag_table` `run.sub:16` should link (it is currently forced to `diag_table_no_daily`).
- [ ] Run sponge step 1 for 1993–2019: `./setup_sponge_station.sh GofME monthly` (about 40 min).
- [ ] Choose the sponge period (`clim` or `2004`) and tau, run step 2, and add the printed lines to `MOM_override`.
- [ ] Optional: add `register_variable_attribute` to `generic_CBED_end` so model-written CBED restarts carry metadata.
- [ ] Optional: make the BGC nudging use its own timescale, since `SPONGE_GT_DAMPING_FILE` is currently ignored.

## FMS/MOM6 traps found so far

- **`read_restart` (FMS2) does no horizontal interpolation.** A regional-size `generic_CBED.res.nc` is read at indices 1..NI, 1..NJ (the SW corner of the regional grid), so CBED starts from zeros. Restarts must be cut to the station grid.
- **The CBED layer axis is registered as `lev`** in `generic_CBED.F90`; the regional file calls it `l`.
- **Climatology time axes need a `modulo` attribute** for `time_interp_external` to repeat them every year. Without it, the times must cover the whole run.
- **Generic tracers are not rescaled in the sponge.** `MOM_generic_tracer` calls `set_up_ALE_sponge_field` without `scale=`, so target files must be in model units (mol kg-1).
- **`SPONGE_GT_DAMPING_FILE` is read but not used.** COBALT tracers are nudged with the T/S `Idamp` from `SPONGE_DAMPING_FILE`, but the GT file must still exist.
- **The non-interpolated ALE branch of `g_tracer_initialize_sponges` has `field_size` commented out**, so `siz` is never set. Use `INTERPOLATE_SPONGE_TIME_SPACE = True`.
- **The COBALT sponge needs `SPONGE = True`**, because the tracers attach to the ALE sponge created for T/S.
- **Damping files are read with the model domain**, so `Idamp` must be NI x NJ.
- **`volcello` must be in a diag file with the same output frequency** (interval and units, e.g. `1 days` is not `24 hours`) as every native 3D field that references it.
- **`run.sub` relinks `diag_table` and `input.nml` on every submit**, so editing the links directly has no effect.
