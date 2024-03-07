#!/bin/bash
set -e

# within the ip2location database, create the table, and insert data from the CSV files
PGPASSWORD="grafana" psql -v ON_ERROR_STOP=1 -h localhost -U "grafana" --dbname ip2location <<-EOSQL
    CREATE OR REPLACE FUNCTION batch_ip_geo(TEXT) RETURNS TABLE(ip_addr TEXT, latitude VARCHAR(20), longitude VARCHAR(20)) AS \$BODY\$ 
    DECLARE
        _ip TEXT;
        _ips TEXT[];
        _ipdec DECIMAL(39,0);
        var_r RECORD;
    BEGIN
        _ips = string_to_array(\$1,',');
        
        FOREACH _ip IN ARRAY _ips
        LOOP 
            IF family(_ip::inet) = 4 THEN
                _ipdec = ipv4_to_decimal(_ip::inet);
            ELSIF family(_ip::inet) = 6 THEN
                _ipdec = ipv6_to_decimal(_ip::inet);
            END;

            FOR var_r IN (
                WITH addr(ip_addr) AS (VALUES (_ip))
                SELECT addr.ip_addr AS addr, geo.latitude AS "lat", geo.longitude AS "long" 
                FROM (SELECT ip_geo.latitude, ip_geo.longitude FROM ip_geo 
                WHERE _ipbig >= ip_from AND country_code != '-' 
                ORDER BY ip_from DESC LIMIT 1) AS geo 
                JOIN addr ON 1=1
            ) 
            LOOP ip_addr := var_r.addr;
                latitude := var_r.lat;
                longitude := var_r.long;
            RETURN NEXT;
            END LOOP;
        END LOOP;
    END
    \$BODY\$
    LANGUAGE plpgsql;

    CREATE OR REPLACE FUNCTION ipv4_to_decimal(inet) RETURNS DECIMAL(39,0) AS 
    \$BODY\$ 
        SELECT \$1 - '0.0.0.0'::inet
    \$BODY\$ 
    LANGUAGE sql strict immutable;

    CREATE OR REPLACE FUNCTION ipv6_to_decimal(inet) RETURNS DECIMAL(39,0) AS
    \$BODY\$ 
    DECLARE
        _group TEXT;
        _groups TEXT[];
        _ipbig BIGINT;
        var_r RECORD;
    BEGIN
        _groups = string_to_array(host(\$1),':');
        
        FOREACH _group IN ARRAY _groups
        LOOP 
            _ipbig = hex_to_bigint(_group);
        END LOOP;
    END
    \$BODY\$ LANGUAGE plpgsql;

    CREATE OR REPLACE FUNCTION ipv6_to_decimal(inet) RETURNS DECIMAL(39,0) AS
    \$BODY\$ 
    DECLARE
        _group TEXT;
        _groups TEXT[];
        _ipbig BIGINT;
        var_r RECORD;
    BEGIN
        _groups = string_to_array(host(\$1),':');
        
        FOREACH _group IN ARRAY _groups
        LOOP 
            _ipbig = hex_to_bigint(_group);
        END LOOP;
    END
    \$BODY\$ LANGUAGE plpgsql;

    CREATE OR REPLACE FUNCTION hex_to_bigint(hexval varchar) RETURNS bigint AS 
    \$BODY\$
    DECLARE
        result bigint;
    BEGIN
        EXECUTE 'SELECT x' || quote_literal(hexval) || '::bigint' INTO result;
        RETURN result;
    END;
    \$BODY\$ 
    LANGUAGE plpgsql IMMUTABLE STRICT;

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