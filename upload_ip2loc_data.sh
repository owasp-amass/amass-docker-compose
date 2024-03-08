#!/bin/bash
set -e

# within the ip2location database, create the table, and insert data from the CSV files
PGPASSWORD="grafana" psql -v ON_ERROR_STOP=1 -h localhost -U "grafana" --dbname ip2location <<-EOSQL
    CREATE OR REPLACE FUNCTION batch_ip_geo(TEXT) RETURNS TABLE(ip_addr TEXT, city VARCHAR(128), latitude VARCHAR(20), longitude VARCHAR(20)) AS \$BODY\$ 
    DECLARE
        _ip TEXT;
        _ips TEXT[];
        _var_r RECORD;
    BEGIN
        _ips = string_to_array(\$1, ',');

        FOREACH _ip IN ARRAY _ips LOOP 
            FOR _var_r IN (
                WITH addr(ip_addr) AS (VALUES (_ip))
                SELECT addr.ip_addr AS addr, geo.city_name AS "city", 
                geo.latitude AS "lat", geo.longitude AS "long" 
                FROM (SELECT ip_geo.city_name, ip_geo.latitude, ip_geo.longitude 
                FROM ip_geo WHERE inet_to_num(_ip::inet) >= ip_from AND country_code != '-' 
                ORDER BY ip_from DESC LIMIT 1) AS geo 
                JOIN addr ON 1=1
            ) LOOP ip_addr = _var_r.addr;
                city = _var_r.city;
                latitude = _var_r.lat;
                longitude = _var_r.long;
                RETURN NEXT;
            END LOOP;
        END LOOP;
    END
    \$BODY\$ LANGUAGE plpgsql IMMUTABLE STRICT;

    CREATE OR REPLACE FUNCTION inet_to_num(inet) RETURNS DECIMAL(39,0) AS \$BODY\$ 
        SELECT \$1 - '0.0.0.0'::inet WHERE family(\$1) = 4 
        UNION ALL
        SELECT ipv6_to_num(\$1) WHERE family(\$1) = 6
        UNION ALL
        SELECT 0 WHERE family(\$1) != 4 AND family(\$1) != 6
    \$BODY\$ LANGUAGE sql IMMUTABLE STRICT;

    CREATE OR REPLACE FUNCTION ipv6_to_num(inet) RETURNS DECIMAL(39,0) AS \$BODY\$ 
    DECLARE
        _groups TEXT[];
        _weight DECIMAL(39,0);
        _ipnum DECIMAL(39,0) = 0;
    BEGIN
        _groups = string_to_array(expand_ipv6(\$1), ':');

        FOR i in 1..8 LOOP
            _weight = 1;

            IF i < 8 THEN
                _weight = 65536 ^ (8 - i);
            END IF;

            _ipnum = _ipnum + (hex_to_bigint(_groups[i]) * _weight);
        END LOOP;

        RETURN _ipnum;
    END
    \$BODY\$ LANGUAGE plpgsql IMMUTABLE STRICT;

    CREATE OR REPLACE FUNCTION expand_ipv6(inet) RETURNS TEXT AS \$BODY\$ 
    DECLARE
        _len1 INT;
        _len2 INT;
        _addr TEXT;
        _missing INT;
        _sides TEXT[];
        _groups1 TEXT[];
        _groups2 TEXT[];
    BEGIN
        _addr = host(\$1);
        _sides = string_to_array(_addr, '::');

        IF cardinality(_sides) = 2 THEN
            _groups1 = string_to_array(_sides[1], ':');
            _groups2 = string_to_array(_sides[2], ':');
            _len1 = cardinality(_groups1);
            _len2 = cardinality(_groups2);
            _missing = (8 - _len1) - _len2;

            IF _len1 > 0 THEN
                _sides[1] = _sides[1] || ':';
            END IF;

            FOR i in 1.._missing LOOP
                _sides[1] = _sides[1] || '0';
                IF i < _missing THEN
                    _sides[1] = _sides[1] || ':';
                END IF;
            END LOOP;

            IF _len2 > 0 THEN
                _sides[1] = _sides[1] || ':' || _sides[2];
            END IF;

            _addr = _sides[1];
        END IF;

        RETURN _addr;
    END
    \$BODY\$ LANGUAGE plpgsql IMMUTABLE STRICT;

    CREATE OR REPLACE FUNCTION hex_to_bigint(hexval varchar) RETURNS BIGINT AS \$BODY\$
    DECLARE
        result BIGINT;
    BEGIN
        EXECUTE 'SELECT x' || quote_literal(hexval) || '::bigint' INTO result;
        RETURN result;
    END;
    \$BODY\$ LANGUAGE plpgsql IMMUTABLE STRICT;

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