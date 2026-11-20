-- Run in an empty database with sqlite3 :memory: < docs/experiments/teammate-access.sql
.bail on
PRAGMA foreign_keys = ON;

CREATE TABLE note (
    id INTEGER PRIMARY KEY,
    current_revision INTEGER NOT NULL
);
CREATE TABLE revision (
    id INTEGER PRIMARY KEY,
    note_id INTEGER NOT NULL REFERENCES note(id)
);
CREATE VIRTUAL TABLE passage USING fts5(body);
CREATE TABLE read_grant (
    person TEXT NOT NULL,
    revision_id INTEGER NOT NULL REFERENCES revision(id),
    PRIMARY KEY (person, revision_id)
);

INSERT INTO note VALUES (1, 101), (2, 201), (3, 301);
INSERT INTO revision VALUES (101, 1), (201, 2), (301, 3);
INSERT INTO passage(rowid, body) VALUES
    (101, 'Launch date awaits localization review.'),
    (201, 'Launch deployment checklist is ready.'),
    (301, 'Private personal conversation about the launch.');
INSERT INTO read_grant VALUES ('alex', 101), ('sam', 101), ('alex', 201);

-- The full-text and direct-citation paths use the same grant and version join.
CREATE VIEW readable AS
SELECT g.person, r.id AS revision_id
FROM read_grant AS g
JOIN revision AS r ON r.id = g.revision_id
JOIN note AS n ON n.id = r.note_id AND n.current_revision = r.id;

-- Keep the fixture's MATCH query connection-local for SQLite's trusted-schema defaults.
CREATE TEMP VIEW launch_hits AS
SELECT readable.person, passage.rowid AS citation
FROM passage JOIN readable ON readable.revision_id = passage.rowid
WHERE passage MATCH 'launch';

-- Any false or NULL result makes sqlite3 exit unsuccessfully.
CREATE TEMP TABLE assertion (description TEXT, passed INTEGER NOT NULL CHECK (passed = 1));
INSERT INTO assertion VALUES
    ('Alex can find two approved updates', (SELECT count(*) = 2 FROM launch_hits WHERE person = 'alex')),
    ('Sam can find only the shared decision', (SELECT count(*) = 1 AND min(citation) = 101 FROM launch_hits WHERE person = 'sam')),
    ('Neither gets the private launch passage', NOT EXISTS (SELECT 1 FROM launch_hits WHERE citation = 301)),
    ('Sam cannot open a copied citation', NOT EXISTS (SELECT 1 FROM readable WHERE person = 'sam' AND revision_id = 201));

DELETE FROM read_grant WHERE person = 'sam' AND revision_id = 101;
INSERT INTO assertion VALUES
    ('Revoked search returns no rows', NOT EXISTS (SELECT 1 FROM launch_hits WHERE person = 'sam')),
    ('Revoked citation is inaccessible', NOT EXISTS (SELECT 1 FROM readable WHERE person = 'sam' AND revision_id = 101)),
    ('Other recipient retains access', EXISTS (SELECT 1 FROM launch_hits WHERE person = 'alex' AND citation = 101));

BEGIN;
INSERT INTO revision VALUES (102, 1);
INSERT INTO passage(rowid, body) VALUES (102, 'Launch date confirmed.');
UPDATE note SET current_revision = 102 WHERE id = 1;
COMMIT;
INSERT INTO assertion VALUES
    ('Replacing a note retires the old grant', NOT EXISTS (SELECT 1 FROM readable WHERE revision_id IN (101, 102)));
INSERT INTO read_grant VALUES ('alex', 102);
INSERT INTO assertion VALUES
    ('Approved revision is searchable', EXISTS (SELECT 1 FROM launch_hits WHERE person = 'alex' AND citation = 102));

SELECT count(*) || ' teammate access checks passed.' FROM assertion;
