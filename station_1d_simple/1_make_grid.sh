#!/bin/bash
#
# Step 1 - the station grid: a 0.4 degree box centred on (LAT, LON),
#          4 x 4 ocean cells, flat bottom at DEPTH.
#
# Reads   config.sh                       STATION, LAT, LON, DEPTH
# Writes  model/INPUT/grids/<STATION>/    the grid files and one .log per FRE-NCtools program
#         model/INPUT/*.nc                links to the grid files the model reads
#
# Needs the FRE-NCtools programs on PATH ("source config.sh" puts them there).
#
set -e
source config.sh

# box edges: centre +- 0.2 degrees
west=$(awk  -v c="$LON" 'BEGIN { printf "%.4f", c - 0.2 }')
east=$(awk  -v c="$LON" 'BEGIN { printf "%.4f", c + 0.2 }')
south=$(awk -v c="$LAT" 'BEGIN { printf "%.4f", c - 0.2 }')
north=$(awk -v c="$LAT" 'BEGIN { printf "%.4f", c + 0.2 }')
echo "Grid for $STATION: lon $west..$east, lat $south..$north, bottom $DEPTH m"

mkdir -p "model/INPUT/grids/$STATION"
cd "model/INPUT/grids/$STATION"

# 1. horizontal grid: 8 x 8 supergrid points = 4 x 4 model cells
make_hgrid --grid_type regular_lonlat_grid --nxbnd 2 --nybnd 2 \
           --xbnd "$west,$east" --ybnd "$south,$north" \
           --nlon 8 --nlat 8 --grid_name ocean_hgrid > make_hgrid.log 2>&1

# 2. one mosaic per component (all on the same grid)
make_solo_mosaic --num_tiles 1 --dir ./ --mosaic_name ocean_mosaic --tile_file ocean_hgrid.nc > make_solo_mosaic_ocean.log 2>&1
make_solo_mosaic --num_tiles 1 --dir ./ --mosaic_name atmos_mosaic --tile_file ocean_hgrid.nc > make_solo_mosaic_atmos.log 2>&1
make_solo_mosaic --num_tiles 1 --dir ./ --mosaic_name land_mosaic  --tile_file ocean_hgrid.nc > make_solo_mosaic_land.log 2>&1

# 3. flat-bottom topography
make_topog --mosaic ocean_mosaic.nc --topog_type rectangular_basin \
           --bottom_depth "$DEPTH" --output ocean_topog.nc > make_topog.log 2>&1

# 4. exchange grids between ocean, atmosphere and land
make_coupler_mosaic --atmos_mosaic atmos_mosaic.nc --land_mosaic land_mosaic.nc \
                    --ocean_mosaic ocean_mosaic.nc --ocean_topog ocean_topog.nc \
                    --mosaic_name grid_spec --check --verbose > make_coupler_mosaic.log 2>&1

# a good grid is 100 % ocean with no tiling error
grep -E "ocean fraction|tiling error" make_coupler_mosaic.log

# link the grid files into model/INPUT/, where the model looks for them
cd ../..                      # now in model/INPUT
for f in ocean_hgrid.nc ocean_topog.nc ocean_mosaic.nc atmos_mosaic.nc land_mosaic.nc \
         land_mask.nc ocean_mask.nc grid_spec.nc \
         atmos_mosaic_tile1Xocean_mosaic_tile1.nc land_mosaic_tile1Xocean_mosaic_tile1.nc; do
    ln -sf "grids/$STATION/$f" "$f"
done
ln -sf ocean_topog.nc topog.nc

echo "Step 1 done: grid in model/INPUT/grids/$STATION/"
