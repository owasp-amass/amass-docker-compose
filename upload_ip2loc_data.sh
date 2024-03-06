#!/bin/bash
set -e

# within the ip2location database, create the table, and insert data from the CSV files
PGPASSWORD="grafana" psql -v ON_ERROR_STOP=1 -h localhost -U "grafana" --dbname ip2location <<-EOSQL
    CREATE OR REPLACE FUNCTION batch_ip_geo(TEXT) RETURNS TABLE(ip_addr TEXT, latitude VARCHAR(20), longitude VARCHAR(20)) AS \$BODY\$ 
    DECLARE
        _ip TEXT;
        _ips TEXT[];
        _ipbig BIGINT;
        var_r RECORD;
    BEGIN
        _ips = string_to_array(\$1,',');
        
        FOREACH _ip IN ARRAY _ips
        LOOP 
            _ipbig = inet_to_bigint(_ip::inet);

            FOR var_r IN (
                WITH addr(ip_addr) AS (VALUES (_ip))
                SELECT addr.ip_addr AS addr, geo.latitude AS lat, geo.longitude AS long 
                FROM (SELECT * FROM ip_geo WHERE _ipbig <= ip_to) AS geo 
                JOIN addr ON 1=1 
                WHERE _ipbig >= ip_from AND country_code != '-' LIMIT 1
            ) 
            LOOP ip_addr := var_r.addr;
                latitude := var_r.lat;
                longitude := var_r.long;
            RETURN NEXT;
            END LOOP;
        END LOOP;
    END
    \$BODY\$ LANGUAGE plpgsql;

    CREATE OR REPLACE FUNCTION inet_to_bigint(inet) RETURNS bigint AS \$BODY\$ 
        SELECT \$1 - '0.0.0.0'::inet WHERE family(\$1) = 4
        UNION ALL
        SELECT '0'::bigint WHERE family(\$1) = 6
    \$BODY\$ LANGUAGE sql strict immutable;

    GRANT execute ON FUNCTION inet_to_bigint(inet) TO public;

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