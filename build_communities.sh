# Build the dataset for a modern demographic map
# USAGE: bash build_communities.sh <State name> <state abbreviation> <state_fips> <county_fips> <census key>

# params
set -eo pipefail
DATE=`date +%Y_%m_%d`
STATE_NAME=$1
STATE_ABBRV=$2
STATE_FIPS=$3
COUNTY_FIPS=$4
CENSUS_KEY=$5
TRIBES_MB_TOKEN=sk.eyJ1IjoibGFuZHBsYW5uZXIiLCJhIjoiY2lsaXFkMng1M2NxMXY2bTBvaXQ0Z2N0eCJ9.dl5GmYgdPdNupaYxk8y16g

MB_USER=landplanner

echo '------------cleaning house------------'
rm -rf data/tmp_$STATE_FIPS"_"$COUNTY_FIPS/

echo '------------creating temp location------------'
mkdir data/tmp_$STATE_FIPS"_"$COUNTY_FIPS/

echo '------------getting ancestry and race data------------'
cd processing/pull
npm install
echo 'getting decennial census data'
node index.js sf1 $CENSUS_KEY $STATE_FIPS $COUNTY_FIPS
echo 'getting american community survey data'
node index.js acs5 $CENSUS_KEY $STATE_FIPS $COUNTY_FIPS
cd ../../data/tmp_$STATE_FIPS"_"$COUNTY_FIPS/
csvjoin -c "tract" sf1.csv acs5.csv > community_attributes.csv
csvcut -c 49-51,1-48,52-104 community_attributes.csv > community_attributes_ordered.csv

echo '------------identifying the largest group in each tract------------'
cd ../../processing/parse
npm install
node index.js ../../data/tmp_$STATE_FIPS"_"$COUNTY_FIPS/community_attributes_ordered.csv

echo '------------joining literate group names------------'
cd ../../data/tmp_$STATE_FIPS"_"$COUNTY_FIPS
mv community_attributes_ordered.csv.tmp community_attributes_ordered_max.csv
csvjoin -c "largest_group,code" --left community_attributes_ordered_max.csv ../census_community_fields.csv > community_properties.csv
csvcut -c "1-4,103-109" community_properties.csv > community_properties_light.csv
sed -i tmp.bak 's/name,/largest_community_name,/g' community_properties_light.csv

echo '------------importing geodata (tracts)------------'
wget -c ftp://ftp2.census.gov/geo/tiger/TIGER2015/TRACT/tl_2015_$STATE_FIPS"_tract.zip"
unzip tl_2015_$STATE_FIPS"_tract.zip"
ogr2ogr -t_srs "EPSG:4326" -f GeoJSON -where "COUNTYFP = '$COUNTY_FIPS'" tracts_$COUNTY_FIPS.geojson tl_2015_$STATE_FIPS"_tract.shp"

echo '------------joining attributes to tract boundaries------------'
cd ../../processing/join
npm install
node index.js ../../data/tmp_$STATE_FIPS"_"$COUNTY_FIPS/tracts_$COUNTY_FIPS.geojson ../../data/tmp_$STATE_FIPS"_"$COUNTY_FIPS/community_properties_light.csv $STATE_FIPS $COUNTY_FIPS

echo '------------importing geodata (OSM water)------------'
 #cd ../water
 #npm install
 ## get the desired area from OSM:
 #COMMUNITY_BBOX=$(psql communities -t -c "SELECT '[' || ST_XMin(ST_Transform(ST_Expand(ST_Collect(ST_Transform(the_geom,3857)),2000),4326)) || ',' || ST_YMin(ST_Transform(ST_Expand(ST_Collect(ST_Transform(the_geom,3857)),2000),4326)) || ',' || ST_XMax(ST_Transform(ST_Expand(ST_Collect(ST_Transform(the_geom,3857)),2000),4326)) || ',' || ST_YMax(ST_Transform(ST_Expand(ST_Collect(ST_Transform(the_geom,3857)),2000),4326)) || ']' FROM community_tracts ;")
 #node index.js $COMMUNITY_BBOX $STATE_FIPS $COUNTY_FIPS ../../data/tmp_$STATE_FIPS"_"$COUNTY_FIPS/osm_water.geojson
 #ogr2ogr -t_srs "EPSG:4326" -f "PostgreSQL" PG:"host=localhost dbname=communities" ../../data/tmp_$STATE_FIPS"_"$COUNTY_FIPS/osm_water.geojson -nln osm_water -lco PRECISION=NO


echo '------------dissolving and eroding community boundaries------------'
# TODO wanted this to be a DB-free joint, but memory limits are hampering turf. PostGIS for now.
#cd ../dissolve
#npm install
cd ../form
#npm install
#node index.js ../../data/tmp_$STATE_FIPS"_"$COUNTY_FIPS/tracts_$COUNTY_FIPS.geojson
#mv erodedTracts.geojson ../../data/tmp_$STATE_FIPS"_"$COUNTY_FIPS/
dropdb communities
createdb communities
psql communities -c "CREATE EXTENSION IF NOT EXISTS postgis"
psql communities -c "CREATE EXTENSION IF NOT EXISTS postgis_topology"
ogr2ogr -t_srs "EPSG:4326" -f "PostgreSQL" PG:"host=localhost dbname=communities" ../../data/tmp_$STATE_FIPS"_"$COUNTY_FIPS/community_tracts_$COUNTY_FIPS.geojson -nln community_tracts -nlt PROMOTE_TO_MULTI -lco PRECISION=NO
cd ../../data/tmp_$STATE_FIPS"_"$COUNTY_FIPS/
psql communities -f ../../processing/form/form.sql

echo '------------exporting final geojson(s)------------'
# CLEAR THE DECKS
rm -f communities_polys.geojson
rm -f communities_points.geojson
rm -f communities_mask.geojson

# EXPORT THE 3 MAP-READY FILES TO THE TMP DATA DIRECTORY
ogr2ogr -f "GeoJSON" communities_polys.geojson PG:"host=localhost dbname=communities" -sql "SELECT * from community_polys WHERE largest_group_count IS NOT NULL AND total_population IS NOT NULL"
ogr2ogr -f "GeoJSON" communities_points.geojson PG:"host=localhost dbname=communities" -sql "SELECT * from community_centroids WHERE largest_group_count IS NOT NULL AND total_population IS NOT NULL"
ogr2ogr -f "GeoJSON" communities_mask.geojson PG:"host=localhost dbname=communities" -sql "SELECT * from community_mask"
# DEFINE DATA LAYER NAMES
POLYS=$MB_USER.communities_$STATE_FIPS"_"$COUNTY_FIPS
POINTS=$MB_USER.communities_points_$STATE_FIPS"_"$COUNTY_FIPS
MASK=$MB_USER.communities_mask_$STATE_FIPS"_"$COUNTY_FIPS

echo '------------uploading geojson to mapbox data'
export MAPBOX_ACCESS_TOKEN=$TRIBES_MB_TOKEN
mapbox upload --name communities_polys $POLYS communities_polys.geojson
mapbox upload --name communities_points $POINTS communities_points.geojson
mapbox upload --name communities_mask $MASK communities_mask.geojson

echo "------------creating mapbox studio project for $STATE_NAME county $COUNTY_FIPS------------"
cd ../../cartography
# CREATE A COUNTY-SPECIFIC MAPBOX STUDIO CLASSIC PROJECT
rm -rf tribes_$STATE_FIPS"_"$COUNTY_FIPS.tm2
cp -r tribes.tm2 tribes_$STATE_FIPS"_"$COUNTY_FIPS.tm2
cd tribes_$STATE_FIPS"_"$COUNTY_FIPS.tm2/
# GET CENTROID OF COUNTY
COUNTY_LAT=$(psql communities -t -c "SELECT ST_Y(ST_Centroid(ST_Collect(the_geom))) FROM community_polys")
COUNTY_LON=$(psql communities -t -c "SELECT ST_X(ST_Centroid(ST_Collect(the_geom))) FROM community_polys")
# REWRITE PROJECT CONFIG FILE
sed -i tmp2.bak "s/name: Tribes/name: Tribes - $STATE_NAME county $COUNTY_FIPS/g" project.yml
sed -i tmp3.bak "s/landplanner.0xsgug3g/$POLYS/g" project.yml
sed -i tmp3.bak "s/landplanner.69rz84n1/$POINTS/g" project.yml
sed -i tmp3.bak "s/landplanner.0ufuyubk/$MASK/g" project.yml
sed -i tmp4.bak "s/- -118.2437/-$COUNTY_LON/g" project.yml
sed -i tmp5.bak "s/- 34.0522/-$COUNTY_LAT/g" project.yml

# EXPORT LEGEND WITH EMPTY GROUPS REMOVED
psql communities -c "\\copy (SELECT * FROM community_legend) TO STDOUT DELIMITER ',' CSV HEADER" | csvgrep -c 2 -r '\S' > legend/community_legend.csv 

cp legend/community_legend.csv bubbles/

# EXPORT LEGEND TO PNG FOR LAYOUT
cd legend/
# START A WEB SERVER
static -p 8000 "$output""$ext" &
STATICPID=$!
sleep 10
echo 'waiting 10s for server to spin up'
# EXPORT THE IMAGE
phantomjs rasterize.js http://localhost:8000/index.html legend.png
# KILL THE WEBSERVER
kill -s 9 $STATICPID
cp legend.png ../img/
cp legend.png ../exports/

# EXPORT BUBBLE CHART TO PNG FOR LAYOUT
cd ../bubbles/
# START A WEB SERVER
static -p 8000 "$output""$ext" &
STATICPID=$!
sleep 10
echo 'waiting 10s for server to spin up'
# EXPORT THE IMAGE
phantomjs rasterize.js http://localhost:8000/index.html bubbles.png
# KILL THE WEBSERVER
kill -s 9 $STATICPID
cp bubbles.png ../img/
cp bubbles.png ../exports/
cd ../../../

# CLEAR OUT THE TEMP DATA TO SAVE SPACE
rm -rf data/tmp/

echo "------------done! go add the project to mapbox studio and you're off to the races!------------"