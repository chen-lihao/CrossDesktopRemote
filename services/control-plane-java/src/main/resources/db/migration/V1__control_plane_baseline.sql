CREATE TABLE control_plane_metadata (
    id SMALLINT PRIMARY KEY,
    schema_version INTEGER NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT control_plane_metadata_singleton CHECK (id = 1),
    CONSTRAINT control_plane_metadata_version_positive CHECK (schema_version > 0)
);

INSERT INTO control_plane_metadata (id, schema_version)
VALUES (1, 1);
