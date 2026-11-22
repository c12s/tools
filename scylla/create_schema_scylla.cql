-- Create keyspace
CREATE KEYSPACE IF NOT EXISTS apollo
WITH REPLICATION = { 'class' : 'SimpleStrategy', 'replication_factor' : 3 };

--USE apollo;

CREATE TABLE IF NOT EXISTS apollo.org (
    name TEXT PRIMARY KEY,
    owner TEXT,
    members SET<TEXT>,
    permissions SET<TEXT>,
    created_at DATE,
    updated_at DATE
)
    WITH bloom_filter_fp_chance = 0.01
    AND caching = {'keys': 'ALL', 'rows_per_partition': 'ALL'};

CREATE TABLE IF NOT EXISTS apollo.permission (
    id UUID PRIMARY KEY,
    name TEXT
);

CREATE TABLE IF NOT EXISTS apollo.user (
    name TEXT,
    surname TEXT,
    email TEXT,
    username TEXT,
    created_at DATE,
    updated_at DATE,
    PRIMARY KEY (username)
);
CREATE INDEX IF NOT EXISTS ON apollo.user (email);
--CREATE INDEX email_user_idx ON apollo.user ({"pk":["username"],"ck":["email"]});

CREATE MATERIALIZED VIEW IF NOT EXISTS apollo.user_by_email AS
    SELECT * FROM apollo.user
    WHERE username IS NOT NULL AND email IS NOT NULL
    PRIMARY KEY (email, username);

-- fixed ids (uuid5 of the name) so re-applying this file is a no-op
INSERT INTO apollo.permission (id, name) VALUES (dfcefefd-e78d-5a22-8605-325cd7f73a33, 'config.get') IF NOT EXISTS;
INSERT INTO apollo.permission (id, name) VALUES (68454a59-d4fe-5ff1-ba18-3ce556e51115, 'config.put') IF NOT EXISTS;
INSERT INTO apollo.permission (id, name) VALUES (4d0a76cc-d37a-54fe-a73b-ebc425473f9e, 'org.namespace.add') IF NOT EXISTS;
INSERT INTO apollo.permission (id, name) VALUES (f4158cbc-5491-5b6e-a485-6e2413959b17, 'org.namespace.get') IF NOT EXISTS;
INSERT INTO apollo.permission (id, name) VALUES (dddcaf93-5e98-5f82-a709-674402ac89ee, 'namespace.delete') IF NOT EXISTS;
INSERT INTO apollo.permission (id, name) VALUES (7fd0d173-9620-5005-a8c0-64eafe495f63, 'namespace.putconfig') IF NOT EXISTS;
INSERT INTO apollo.permission (id, name) VALUES (b98aab99-9ffe-5e46-ab63-21ed352a3563, 'namespace.put') IF NOT EXISTS; -- za bilo kakve izmene ns i dodelu resursa
INSERT INTO apollo.permission (id, name) VALUES (d4d8dfc4-12fb-5630-b403-02e827a65219, 'namespace.app.add') IF NOT EXISTS;
INSERT INTO apollo.permission (id, name) VALUES (006e06c6-a5be-5cff-933f-42036c023b7e, 'app.delete') IF NOT EXISTS;
INSERT INTO apollo.permission (id, name) VALUES (6c2e7371-b19c-5c1b-99ac-87df414521d5, 'app.put') IF NOT EXISTS; -- dodela resursa app
INSERT INTO apollo.permission (id, name) VALUES (3cf1b191-f085-50d6-bbd1-8ad45a430680, 'node.get') IF NOT EXISTS;
INSERT INTO apollo.permission (id, name) VALUES (36ad29b2-1273-5938-b92e-32338768457f, 'node.put') IF NOT EXISTS;
INSERT INTO apollo.permission (id, name) VALUES (3e15dd4f-1330-5b7c-92b6-97b3946966a0, 'node.label.put') IF NOT EXISTS;
INSERT INTO apollo.permission (id, name) VALUES (b51ee210-ad10-550e-b3b1-4bdc8ff0741d, 'node.label.get') IF NOT EXISTS;
INSERT INTO apollo.permission (id, name) VALUES (8955fc50-c37f-55ab-b91c-975f186a1394, 'node.label.delete') IF NOT EXISTS;
INSERT INTO apollo.permission (id, name) VALUES (4c3a6383-525c-5f32-b0ff-1402ee79f47d, 'org.add') IF NOT EXISTS;
INSERT INTO apollo.permission (id, name) VALUES (6f54d9a6-c7e9-5cb0-a658-d7d1cc413037, 'config.send') IF NOT EXISTS;
INSERT INTO apollo.permission (id, name) VALUES (8b69fb36-63c2-54e8-908e-dffde87bc925, 'config.app.send') IF NOT EXISTS;
INSERT INTO apollo.permission (id, name) VALUES (0015116c-6c21-558d-ab5e-b38cccf5184c, 'scmp.sys.admin') IF NOT EXISTS;