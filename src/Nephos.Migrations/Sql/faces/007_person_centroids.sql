CREATE TABLE person_centroids (
    owner text NOT NULL,
    pipeline_version text NOT NULL,
    person_id uuid NOT NULL,
    centroid real[] NOT NULL,
    observation_count integer NOT NULL CHECK (observation_count > 0),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(owner, pipeline_version, person_id),
    FOREIGN KEY(owner, person_id) REFERENCES people(owner, id) ON DELETE CASCADE
);

CREATE INDEX observations_owner_track_conf ON observations(owner, track_id, confidence DESC, id DESC);
GRANT SELECT, INSERT, UPDATE, DELETE ON person_centroids TO faces_app;

-- Backfill normalized per-person centroids for any pre-existing completed observations.
WITH attributed AS (
    SELECT o.owner,
           j.pipeline_version,
           CASE WHEN t.manual_override THEN t.manual_person_id ELSE o.generated_person_id END AS person_id,
           o.embedding,
           row_number() OVER (
               PARTITION BY o.owner, j.pipeline_version,
                   CASE WHEN t.manual_override THEN t.manual_person_id ELSE o.generated_person_id END
               ORDER BY o.confidence DESC, j.created_at DESC, o.id DESC
           ) AS pos
    FROM observations o
    JOIN jobs j ON j.id = o.job_id
    JOIN face_tracks t ON t.id = o.track_id
    WHERE j.status = 'complete'
      AND o.embedding IS NOT NULL
      AND array_length(o.embedding, 1) = 128
),
capped AS (
    SELECT owner, pipeline_version, person_id, embedding
    FROM attributed
    WHERE person_id IS NOT NULL AND pos <= 256
),
counts AS (
    SELECT owner, pipeline_version, person_id, count(*)::integer AS observation_count
    FROM capped
    GROUP BY owner, pipeline_version, person_id
),
summed AS (
    SELECT c.owner, c.pipeline_version, c.person_id, u.idx, sum(u.val::double precision) AS total
    FROM capped c
    CROSS JOIN LATERAL unnest(c.embedding) WITH ORDINALITY AS u(val, idx)
    GROUP BY c.owner, c.pipeline_version, c.person_id, u.idx
),
norms AS (
    SELECT owner, pipeline_version, person_id, sqrt(sum(total * total)) AS norm
    FROM summed
    GROUP BY owner, pipeline_version, person_id
    HAVING sqrt(sum(total * total)) > 0
)
INSERT INTO person_centroids(owner, pipeline_version, person_id, centroid, observation_count, updated_at)
SELECT s.owner,
       s.pipeline_version,
       s.person_id,
       array_agg((s.total / n.norm)::real ORDER BY s.idx),
       cnt.observation_count,
       now()
FROM summed s
JOIN norms n ON n.owner = s.owner AND n.pipeline_version = s.pipeline_version AND n.person_id = s.person_id
JOIN counts cnt ON cnt.owner = s.owner AND cnt.pipeline_version = s.pipeline_version AND cnt.person_id = s.person_id
GROUP BY s.owner, s.pipeline_version, s.person_id, cnt.observation_count
ON CONFLICT (owner, pipeline_version, person_id) DO NOTHING;
