-- Create shared user 'stratium' for both databases
CREATE USER stratium WITH PASSWORD 'stratium';

-- Create stratium_pap database
CREATE DATABASE stratium_pap;
GRANT ALL PRIVILEGES ON DATABASE stratium_pap TO stratium;

-- Create stratium_keymanager database
CREATE DATABASE stratium_keymanager;
GRANT ALL PRIVILEGES ON DATABASE stratium_keymanager TO stratium;
