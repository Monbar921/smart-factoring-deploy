create database smart_factoring_test;

create schema smart_factoring_test;

create user smart_factoring_app with password 'pass';

grant connect on database smart_factoring_test to smart_factoring_app;

GRANT USAGE, CREATE ON SCHEMA smart_factoring_test TO smart_factoring_app;

-- 2. Права на работу с уже существующими таблицами
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA smart_factoring_test TO smart_factoring_app;

-- 3. Права на работу с последовательностями (нужно для SERIAL/IDENTITY колонок)
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA smart_factoring_test TO smart_factoring_app;

-- 4. Автоматические права на БУДУЩИЕ таблицы и последовательности
ALTER DEFAULT PRIVILEGES IN SCHEMA smart_factoring_test
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO smart_factoring_app;

ALTER DEFAULT PRIVILEGES IN SCHEMA smart_factoring_test
    GRANT USAGE, SELECT ON SEQUENCES TO smart_factoring_app;