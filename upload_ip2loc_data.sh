#!/bin/bash
set -e

eval $(grep -v -e '^#' ./config/assetdb.env | xargs -I {} echo export \'{}\')

# insert data from the CSV files within the ip2location database
PGPASSWORD=$AMASS_PASSWORD psql -v ON_ERROR_STOP=1 -h localhost -p 55432 -U "$AMASS_USER" --dbname ip2location <<-EOSQL
    DROP TABLE IF EXISTS ip_geo;
    CREATE TABLE ip_geo (
        ip_from DECIMAL(39,0) NOT NULL,
        ip_to DECIMAL(39,0) NOT NULL,
        country_code CHAR(2) NOT NULL,
        country_name VARCHAR(64) NOT NULL,
        region_name VARCHAR(128) NOT NULL,
        city_name VARCHAR(128) NOT NULL,
        latitude VARCHAR(20) NOT NULL,
        longitude VARCHAR(20) NOT NULL,
        zip_code VARCHAR(30) NULL DEFAULT NULL,
        time_zone VARCHAR(8) NULL DEFAULT NULL,
        CONSTRAINT idx_key PRIMARY KEY (ip_to)
    );

    \copy ip_geo from 'IP2LOCATION-LITE-DB11.CSV' with (format 'csv', quote '"')
    \copy ip_geo from 'IP2LOCATION-LITE-DB11.IPV6.CSV' with (format 'csv', quote '"')

    CREATE INDEX ip_from_number ON ip_geo(ip_from);
EOSQL