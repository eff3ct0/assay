PRAGMA journal_mode=DELETE;
CREATE TABLE IF NOT EXISTS repos(repo TEXT PRIMARY KEY, tip TEXT NOT NULL, state TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS changes(repo TEXT, sha TEXT, time INTEGER, pr INTEGER, revert INTEGER, PRIMARY KEY(repo,sha));
CREATE INDEX IF NOT EXISTS changes_time ON changes(time);
-- The raw, versioned measure document retains nulls for unavailable probes.
CREATE TABLE IF NOT EXISTS snapshots(repo TEXT, tip TEXT, time INTEGER, metrics TEXT, error TEXT);
CREATE TABLE IF NOT EXISTS checks(repo TEXT, name TEXT, PRIMARY KEY(repo,name));
CREATE TABLE IF NOT EXISTS hits(repo TEXT, event TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS batches(id TEXT PRIMARY KEY);
CREATE VIEW IF NOT EXISTS failures AS
 SELECT repo, unixepoch(event->>'time') AS time, event->>'agent' AS agent, event->>'rule' AS name
 FROM hits WHERE event->>'source' IN ('guard','git-hook')
 UNION ALL
 SELECT repo, unixepoch(event->>'time'), event->>'agent', f.value
 FROM hits, json_each(event,'$.failed') f WHERE event->>'source'='check';
CREATE TABLE IF NOT EXISTS rules(name TEXT PRIMARY KEY);
