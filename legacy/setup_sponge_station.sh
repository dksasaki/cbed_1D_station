#!/bin/bash
#
# Build the T/S and BGC (o2, no3, dic, alk) nudging files for the station this
# experiment runs at, on the station grid (use with SPONGE_DATA_ONGRID = True).
#
#   ./setup_sponge_station.sh                                list sponge states already built
#   ./setup_sponge_station.sh <name>                         activate an existing sponge state
#   ./setup_sponge_station.sh <name> monthly                 step 1: station monthly means, 1993-2019
#   ./setup_sponge_station.sh <name> build [clim|YYYY|YYYY-YYYY] [tau_days]
#                                                            step 2: 12-month sponge files, then activate
#
#   e.g.  ./setup_sponge_station.sh GofME monthly           # once; slow (reads the daily COBALT files)
#         ./setup_sponge_station.sh GofME build clim 30     # 1993-2019 climatology, 30-day nudging
#         ./setup_sponge_station.sh GofME build 2004 10     # 2004 monthly means, 10-day nudging
#         ./setup_sponge_station.sh GofME                   # switch back later
#
# Sources (override with the environment variables of the same name):
#   GLORYS_DIR  monthly-mean GLORYS T/S on its own grid, one file per month (YYYY-MM.nc)
#   COBALT_DIR  NEUS25 COBALT daily z-level output (YYYYMM01.ocean_cobalt_tracers_daily_z.nc)
#   MIN_VALID_DAYS  fewest valid daily COBALT records for a month to be used (default 15)
#
# Some COBALT files end early: their last records have time = 0 and all-zero
# fields. Only days whose time stamp falls inside the file's month are
# averaged; the valid days and the missing date ranges are written to
# INPUT/sponge/<name>/monthly.log.
#
# Step 1 takes, for every ocean cell of INPUT/grids/<name>/ocean_hgrid.nc, the
# nearest wet column of each source and stores its monthly means as a time
# series (months missing in a source are left as fill values):
#   INPUT/sponge/<name>/monthly_ts.nc    thetao, so    (GLORYS levels)
#   INPUT/sponge/<name>/monthly_bgc.nc   o2, no3, dic, alk  (COBALT z_l levels, mol kg-1;
#                                        dic, alk from dissic, talk [mol m-3] / RHO_0)
#
# Step 2 reduces those to one 12-month cycle, either a multi-year climatology
# ("clim") or the monthly means of one year (YYYY, with gaps filled from the
# climatology). The time axis carries a "modulo" attribute, so FMS repeats it
# every year, which matches the repeat-year 2004 forcing. A range (YYYY-YYYY)
# instead writes the real monthly means of those years on a calendar time axis
# without "modulo", padded with December of the year before and January of the
# year after (climatology where missing), for multi-year runs such as
# run_years.sh; the run must stay inside that range:
#   INPUT/sponge/<name>/sponge_ts.nc       temp, salt
#   INPUT/sponge/<name>/sponge_bgc.nc      o2, no3, dic, alk
#   INPUT/sponge/<name>/sponge_damping.nc  Idamp = 1/tau  [s-1]
# Activation links these into INPUT/. Nothing in MOM_input/MOM_override is
# changed; the parameters to add are printed at the end.

set -e -o pipefail

expdir="$(cd "$(dirname "$0")" && pwd)"
cd "$expdir"

GLORYS_DIR="${GLORYS_DIR:-/home/d.sasaki/schultz/data/glorys/nwa25_regional/monthly_average}"
COBALT_DIR="${COBALT_DIR:-/home/d.sasaki/scratch/serving_files/test_004}"
# A COBALT month with fewer valid daily records than this is treated as missing.
MIN_VALID_DAYS="${MIN_VALID_DAYS:-15}"
SPONGE_FILES="sponge_ts.nc sponge_bgc.nc sponge_damping.nc"

list_sponge() {
    if [ -d INPUT/sponge ] && [ -n "$(ls -A INPUT/sponge 2>/dev/null)" ]; then
        echo "Sponge states (activate with: $0 <name>):"
        for d in INPUT/sponge/*/; do
            name=$(basename "$d")
            built=$(cat "$d/build.txt" 2>/dev/null || echo "monthly means only")
            printf "  %-16s %s\n" "$name" "$built"
        done
    else
        echo "No sponge states built yet."
        echo "Build one with: $0 <station_name> monthly ; $0 <station_name> build [clim|YYYY|YYYY-YYYY] [tau_days]"
    fi
    active=$(readlink INPUT/sponge_ts.nc 2>/dev/null || true)
    [ -n "$active" ] && echo "Active: INPUT/sponge_ts.nc -> $active"
    return 0
}

usage() {
    echo "usage: $0                                      list sponge states already built" >&2
    echo "       $0 <name>                               activate an existing sponge state" >&2
    echo "       $0 <name> monthly                       station monthly means (step 1)" >&2
    echo "       $0 <name> build [clim|YYYY|YYYY-YYYY] [tau_days]  12-month sponge files, then activate (step 2)" >&2
}

case "$#" in
    0) list_sponge; exit 0 ;;
    1) mode=activate ;;
    2|3|4)
        case "$2" in
            monthly) [ "$#" -eq 2 ] || { usage; exit 1; }; mode=monthly ;;
            build) mode=build ;;
            *) usage; exit 1 ;;
        esac ;;
    *) usage; exit 1 ;;
esac

station="$1"
spdir="INPUT/sponge/$station"
hgrid="INPUT/grids/$station/ocean_hgrid.nc"

if [ "$mode" = monthly ]; then
    if [ ! -e "$hgrid" ]; then
        echo "ERROR: no station grid $hgrid." >&2
        echo "       Build it first: ./setup_station.sh $station <latitude> <longitude> [depth]" >&2
        exit 1
    fi
    for d in "$GLORYS_DIR" "$COBALT_DIR"; do
        [ -d "$d" ] || { echo "ERROR: source directory '$d' not found." >&2; exit 1; }
    done
    mkdir -p "$spdir"
    echo "Station monthly means for $station"
    echo "  T/S: $GLORYS_DIR"
    echo "  BGC: $COBALT_DIR"

    python3 -I - "$hgrid" "$GLORYS_DIR" "$COBALT_DIR" "$spdir" "$MIN_VALID_DAYS" <<'PY' | tee "$spdir/monthly.log"
import sys, os, calendar, datetime
import cftime
import warnings
import numpy as np
warnings.filterwarnings("ignore", "Mean of empty slice")
import netCDF4

hgrid, glorys_dir, cobalt_dir, spdir = sys.argv[1:5]
min_days = int(sys.argv[5])
FILL = np.float32(1.0e20)
YEARS = range(1993, 2020)
months = [(y, m) for y in YEARS for m in range(1, 13)]

g = netCDF4.Dataset(hgrid)
lon = np.asarray(g.variables['x'][1::2, 1::2])
lat = np.asarray(g.variables['y'][1::2, 1::2])
g.close()
nj, ni = lon.shape
coslat = np.cos(np.deg2rad(lat.mean()))


def nearest_wet(sx, sy, wet, label):
    """(j, i) of the nearest wet source column for every station cell."""
    SX, SY = np.meshgrid(sx, sy)
    wj, wi = np.nonzero(wet)
    pick = np.zeros((nj, ni, 2), dtype=int)
    for j in range(nj):
        for i in range(ni):
            d2 = ((SX[wj, wi] - lon[j, i]) * coslat) ** 2 + (SY[wj, wi] - lat[j, i]) ** 2
            k = int(np.argmin(d2))
            pick[j, i] = wj[k], wi[k]
            print(f"  {label} cell ({i+1},{j+1}) {lat[j,i]:8.3f}N {lon[j,i]:9.3f}E <- (i={wi[k]}, j={wj[k]}) "
                  f"{sy[wj[k]]:8.3f}N {sx[wi[k]]:9.3f}E, {np.sqrt(d2[k]) * 111.0:5.1f} km")
    return pick


def write_monthly(out, zname, z, zattrs, fields, source):
    o = netCDF4.Dataset(out, 'w', format='NETCDF3_64BIT_OFFSET')
    o.createDimension('time', None)
    o.createDimension(zname, z.size)
    o.createDimension('y', nj)
    o.createDimension('x', ni)
    t = o.createVariable('time', 'f8', ('time',))
    t.setncatts(dict(units='days since 1993-01-01 00:00:00', calendar='julian',
                     cartesian_axis='T', long_name='middle of month'))
    t[:] = netCDF4.date2num([cftime.datetime(y, m, 15, calendar='julian') for y, m in months],
                            t.units, t.calendar)
    v = o.createVariable(zname, 'f8', (zname,))
    v.setncatts(zattrs)
    v[:] = z
    for name, vals, attrs in (('y', lat[:, 0], dict(units='degrees_north', cartesian_axis='Y')),
                              ('x', lon[0, :], dict(units='degrees_east', cartesian_axis='X'))):
        v = o.createVariable(name, 'f8', (name,))
        v.setncatts(attrs)
        v[:] = vals
    for name, (data, attrs) in fields.items():
        v = o.createVariable(name, 'f4', ('time', zname, 'y', 'x'), fill_value=FILL)
        v.setncatts(dict(attrs, missing_value=FILL))
        v.set_auto_mask(False)
        v[:] = np.where(np.isfinite(data), data, FILL).astype('f4')
    o.source = source
    o.history = "station monthly means by setup_sponge_station.sh"
    o.close()
    print(f"wrote {out}")


def slab_bounds(pick):
    jj, ii = pick[..., 0], pick[..., 1]
    return jj.min(), jj.max() + 1, ii.min(), ii.max() + 1


# ---- T/S from GLORYS (already monthly means) ----
gfiles = {(y, m): os.path.join(glorys_dir, f"{y}-{m:02d}.nc") for y, m in months}
ref = netCDF4.Dataset(next(f for f in gfiles.values() if os.path.exists(f)))
ref.set_auto_mask(False)
gx = np.asarray(ref['longitude'][:], 'f8'); gy = np.asarray(ref['latitude'][:], 'f8')
gz = np.asarray(ref['depth'][:], 'f8')
wet = np.isfinite(ref['thetao'][0, 0, :, :])
ref.close()
pick = nearest_wet(gx, gy, wet, 'GLORYS')
j0, j1, i0, i1 = slab_bounds(pick)
jj, ii = pick[..., 0] - j0, pick[..., 1] - i0
ts = {k: np.full((len(months), gz.size, nj, ni), np.nan) for k in ('thetao', 'so')}
missing = []
for n, ym in enumerate(months):
    if not os.path.exists(gfiles[ym]):
        missing.append(ym); continue
    d = netCDF4.Dataset(gfiles[ym]); d.set_auto_mask(False)
    for k in ts:
        a = np.asarray(d[k][0, :, j0:j1, i0:i1], 'f8')
        ts[k][n] = a[:, jj, ii]
    d.close()
print(f"GLORYS: {len(months) - len(missing)} months read, missing {missing}")
write_monthly(os.path.join(spdir, 'monthly_ts.nc'), 'depth', gz,
              dict(units='m', positive='down', cartesian_axis='Z'),
              dict(thetao=(ts['thetao'], dict(units='degC', long_name='potential temperature')),
                   so=(ts['so'], dict(units='psu', long_name='practical salinity'))),
              glorys_dir)

# ---- o2, no3 from COBALT daily output (monthly mean of each file) ----
cfiles = {(y, m): os.path.join(cobalt_dir, f"{y}{m:02d}01.ocean_cobalt_tracers_daily_z.nc") for y, m in months}
ref = netCDF4.Dataset(next(f for f in cfiles.values() if os.path.exists(f)))
ref.set_auto_mask(False)
cx = np.asarray(ref['xh'][:]); cy = np.asarray(ref['yh'][:]); cz = np.asarray(ref['z_l'][:])
top = np.asarray(ref['o2'][0, 0, :, :])
wet = np.isfinite(top) & (np.abs(top) < 1e19)
ref.close()
pick = nearest_wet(cx, cy, wet, 'COBALT')
j0, j1, i0, i1 = slab_bounds(pick)
jj, ii = pick[..., 0] - j0, pick[..., 1] - i0


def date_ranges(days):
    """Collapse a sorted list of datetime.date into 'start..end' strings."""
    out, start, prev = [], None, None
    for day in days:
        if start is None:
            start = prev = day
        elif (day - prev).days == 1:
            prev = day
        else:
            out.append(f"{start}..{prev}" if prev != start else f"{start}"); start = prev = day
    if start is not None:
        out.append(f"{start}..{prev}" if prev != start else f"{start}")
    return out


# Daily means are stamped at the end of their day, so day d is valid when
# (time - 0.5 day) falls inside the file's month. Records left unwritten
# (time = 0, fields = 0) fail that test and are dropped.
# model tracer <- (COBALT variable, factor to mol kg-1); dissic, talk are mol m-3
RHO_0 = 1035.0          # [kg m-3], as in MOM_input
BGC_SRC = {'o2': ('o2', 1.0), 'no3': ('no3', 1.0),
           'dic': ('dissic', 1.0 / RHO_0), 'alk': ('talk', 1.0 / RHO_0)}
bgc = {k: np.full((len(months), cz.size, nj, ni), np.nan) for k in BGC_SRC}
missing_days, dropped = [], []
for n, (y, m) in enumerate(months):
    expected = [datetime.date(y, m, k) for k in range(1, calendar.monthrange(y, m)[1] + 1)]
    if not os.path.exists(cfiles[(y, m)]):
        missing_days += expected; dropped.append(f"{y}-{m:02d} (no file)")
        print(f"  COBALT {y}-{m:02d}: file missing", flush=True)
        continue
    d = netCDF4.Dataset(cfiles[(y, m)]); d.set_auto_mask(False)
    t = d['time']
    dates = cftime.num2date(np.asarray(t[:], 'f8') - 0.5, t.units, getattr(t, 'calendar', 'julian'))
    valid = np.array([(x.year, x.month) == (y, m) for x in dates])
    slab = {}
    for k in bgc:
        src, fac = BGC_SRC[k]
        a = np.asarray(d[src][:, :, j0:j1, i0:i1], 'f8')
        a[np.abs(a) >= 1e19] = np.nan
        # Belt and braces: a record that is exactly zero everywhere was never written.
        valid &= ~np.all((a == 0) | np.isnan(a), axis=(1, 2, 3))
        slab[k] = a * fac
    d.close()
    have = sorted({datetime.date(x.year, x.month, x.day) for x, ok in zip(dates, valid) if ok})
    gap = [day for day in expected if day not in have]
    missing_days += gap
    status = f"{len(have)}/{len(expected)} valid days"
    if gap:
        status += f", missing {', '.join(date_ranges(gap))}"
    if len(have) < min_days:
        dropped.append(f"{y}-{m:02d} ({len(have)} valid days)")
        status += f" -> month dropped (< {min_days} days)"
    else:
        for k in bgc:
            bgc[k][n] = np.nanmean(slab[k][valid], axis=0)[:, jj, ii]
    print(f"  COBALT {y}-{m:02d}: {status}", flush=True)
print(f"COBALT: {len(months) - len(dropped)} of {len(months)} months used (minimum {min_days} valid days)")
print(f"COBALT months dropped: {', '.join(dropped) if dropped else 'none'}")
print(f"COBALT missing date ranges: {', '.join(date_ranges(sorted(missing_days))) if missing_days else 'none'}")
write_monthly(os.path.join(spdir, 'monthly_bgc.nc'), 'z_l', cz,
              dict(units='m', positive='down', cartesian_axis='Z'),
              dict(o2=(bgc['o2'], dict(units='mol kg-1', long_name='Oxygen')),
                   no3=(bgc['no3'], dict(units='mol kg-1', long_name='Nitrate')),
                   dic=(bgc['dic'], dict(units='mol kg-1', long_name='Dissolved Inorganic Carbon (dissic / RHO_0)')),
                   alk=(bgc['alk'], dict(units='mol kg-1', long_name='Total Alkalinity (talk / RHO_0)'))),
              cobalt_dir)
PY
    echo "Monthly means for '$station' are in $spdir/. Next: $0 $station build [clim|YYYY|YYYY-YYYY] [tau_days]"
    exit 0
fi

if [ "$mode" = build ]; then
    period="${3:-clim}"
    tau="${4:-30}"
    case "$period" in clim|[12][0-9][0-9][0-9]|[12][0-9][0-9][0-9]-[12][0-9][0-9][0-9]) ;; *) usage; exit 1 ;; esac
    for f in monthly_ts.nc monthly_bgc.nc; do
        [ -e "$spdir/$f" ] || { echo "ERROR: $spdir/$f missing. Run first: $0 $station monthly" >&2; exit 1; }
    done
    echo "Building sponge files for $station: period=$period, tau=$tau days"

    python3 -I - "$spdir" "$period" "$tau" <<'PY' | tee "$spdir/build.log"
import sys, os
import warnings
import numpy as np
warnings.filterwarnings("ignore", "Mean of empty slice")
import netCDF4
import cftime

spdir, period, tau = sys.argv[1], sys.argv[2], float(sys.argv[3])
FILL = np.float32(1.0e20)
# Middle of each month of a 365-day year; with "modulo" FMS repeats this cycle every year.
ndays = np.array([31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31])
tmid = np.cumsum(ndays) - ndays / 2.0


def cycle(src, out, rename):
    s = netCDF4.Dataset(src); s.set_auto_mask(False)
    t = s['time']
    dates = netCDF4.num2date(t[:], t.units, t.calendar)
    years = np.array([d.year for d in dates]); mons = np.array([d.month for d in dates])
    zname = [n for n in s.dimensions if n not in ('time', 'y', 'x')][0]
    o = netCDF4.Dataset(out, 'w', format='NETCDF3_64BIT_OFFSET')
    o.createDimension('time', None)
    for n in (zname, 'y', 'x'):
        o.createDimension(n, s.dimensions[n].size)
    if '-' in period:
        ya, yb = map(int, period.split('-'))
        # real months of ya..yb, padded so that a run from ya-01-01 to (yb+1)-01-01 stays inside
        months = [(ya - 1, 12)] + [(yy, mm) for yy in range(ya, yb + 1) for mm in range(1, 13)] + [(yb + 1, 1)]
        tunits = f'days since {ya-1}-01-01 00:00:00'
        tattrs = dict(units=tunits, calendar='julian', cartesian_axis='T', long_name='middle of month')
        tvals = netCDF4.date2num([cftime.datetime(yy, mm, 15, calendar='julian') for yy, mm in months],
                                 tunits, 'julian')
    else:
        tattrs = dict(units='days since 0001-01-01 00:00:00', calendar='julian',
                      cartesian_axis='T', modulo=' ', long_name='middle of climatological month')
        tvals = tmid
    v = o.createVariable('time', 'f8', ('time',))
    v.setncatts(tattrs)
    v[:] = tvals
    for n in (zname, 'y', 'x'):
        v = o.createVariable(n, 'f8', (n,))
        v.setncatts({k: s[n].getncattr(k) for k in s[n].ncattrs()})
        v[:] = s[n][:]
    for src_name, dst_name in rename.items():
        a = np.asarray(s[src_name][:], 'f8')
        a[np.abs(a) >= 1e19] = np.nan
        clim = np.full((12,) + a.shape[1:], np.nan)
        with np.errstate(invalid='ignore'):
            for m in range(1, 13):
                clim[m - 1] = np.nanmean(a[mons == m], axis=0)
        if period == 'clim':
            ref = clim
            used = f"climatology {years.min()}-{years.max()}"
        elif '-' in period:
            ref = np.full((len(months),) + a.shape[1:], np.nan)
            for n, (yy, mm) in enumerate(months):
                sel = (years == yy) & (mons == mm)
                if sel.any():
                    ref[n] = a[sel][0]
                if not np.isfinite(ref[n]).any():
                    print(f"  {dst_name}: {yy}-{mm:02d} missing, using climatology for that month")
                    ref[n] = clim[mm - 1]
            used = f"monthly means {ya}-{yb}, padded with {ya - 1}-12 and {yb + 1}-01"
        else:
            yr = int(period)
            ref = np.full_like(clim, np.nan)
            for m in range(1, 13):
                sel = (years == yr) & (mons == m)
                if sel.any():
                    ref[m - 1] = a[sel][0]
                if not np.isfinite(ref[m - 1]).any():
                    print(f"  {dst_name}: {yr}-{m:02d} missing, using climatology for that month")
                    ref[m - 1] = clim[m - 1]
            used = f"monthly means of {yr}"
        v = o.createVariable(dst_name, 'f4', ('time', zname, 'y', 'x'), fill_value=FILL)
        v.setncatts({k: s[src_name].getncattr(k) for k in s[src_name].ncattrs() if k != '_FillValue'})
        v.set_auto_mask(False)
        v[:] = np.where(np.isfinite(ref), ref, FILL).astype('f4')
        top = ref[:, 0].reshape(ref.shape[0], -1)
        print(f"  {dst_name:5s} surface range {np.nanmin(top):.4g} .. {np.nanmax(top):.4g} {s[src_name].units}")
    o.source = src
    o.history = f"12-month sponge reference ({used}) by setup_sponge_station.sh"
    o.close()
    s.close()
    print(f"wrote {out} ({used})")


cycle(os.path.join(spdir, 'monthly_ts.nc'), os.path.join(spdir, 'sponge_ts.nc'),
      dict(thetao='temp', so='salt'))
cycle(os.path.join(spdir, 'monthly_bgc.nc'), os.path.join(spdir, 'sponge_bgc.nc'),
      dict(o2='o2', no3='no3', dic='dic', alk='alk'))

s = netCDF4.Dataset(os.path.join(spdir, 'monthly_ts.nc'))
o = netCDF4.Dataset(os.path.join(spdir, 'sponge_damping.nc'), 'w', format='NETCDF3_64BIT_OFFSET')
for n in ('y', 'x'):
    o.createDimension(n, s.dimensions[n].size)
    v = o.createVariable(n, 'f8', (n,))
    v.setncatts({k: s[n].getncattr(k) for k in s[n].ncattrs()})
    v[:] = s[n][:]
v = o.createVariable('Idamp', 'f8', ('y', 'x'))
v.setncatts(dict(units='s-1', long_name=f'inverse nudging timescale (tau = {tau:g} days)'))
v[:] = np.full((s.dimensions['y'].size, s.dimensions['x'].size), 1.0 / (tau * 86400.0))
o.close(); s.close()
print(f"wrote {os.path.join(spdir, 'sponge_damping.nc')} (Idamp = {1.0 / (tau * 86400.0):.4e} s-1)")
PY
    echo "period=$period tau=${tau}d ($(date '+%Y-%m-%d'))" > "$spdir/build.txt"
else
    for f in $SPONGE_FILES; do
        if [ ! -e "$spdir/$f" ]; then
            echo "ERROR: no sponge state for '$station' ($spdir/$f missing)." >&2
            echo "       Build it first: $0 $station monthly ; $0 $station build [clim|YYYY|YYYY-YYYY] [tau_days]" >&2
            echo >&2
            list_sponge >&2
            exit 1
        fi
    done
    echo "Activating existing sponge state for $station"
fi

# Point the sponge files the model reads at the chosen station.
( cd INPUT && for f in $SPONGE_FILES; do ln -sfn "sponge/$station/$f" "$f"; done )

echo "Sponge state '$station' is now active in INPUT/ ($(cat "$spdir/build.txt"))."
cat <<'EOF'

Add to MOM_override to use it:
  SPONGE = True
  INTERPOLATE_SPONGE_TIME_SPACE = True
  SPONGE_DATA_ONGRID = True
  SPONGE_DAMPING_FILE = "sponge_damping.nc"
  SPONGE_STATE_FILE = "sponge_ts.nc"
  SPONGE_PTEMP_VAR = "temp"
  SPONGE_SALT_VAR = "salt"
  DO_SPONGE_GENERIC_TRACER = True
  SPONGE_GT_DAMPING_FILE = "sponge_damping.nc"
  DO_SPONGE_GT_o2 = True
  SPONGE_GT_o2_FILE = "sponge_bgc.nc"
  SPONGE_GT_o2_VAR = "o2"
  DO_SPONGE_GT_no3 = True
  SPONGE_GT_no3_FILE = "sponge_bgc.nc"
  SPONGE_GT_no3_VAR = "no3"
  DO_SPONGE_GT_dic = True
  SPONGE_GT_dic_FILE = "sponge_bgc.nc"
  SPONGE_GT_dic_VAR = "dic"
  DO_SPONGE_GT_alk = True
  SPONGE_GT_alk_FILE = "sponge_bgc.nc"
  SPONGE_GT_alk_VAR = "alk"
EOF
