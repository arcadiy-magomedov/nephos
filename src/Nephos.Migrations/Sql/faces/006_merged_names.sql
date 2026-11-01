WITH labels AS (
    SELECT owner, resolve_person(owner,id) AS root, array_agg(DISTINCT name ORDER BY name) AS names
    FROM people WHERE name IS NOT NULL
    GROUP BY owner, resolve_person(owner,id)
)
UPDATE people target SET name=labels.names[1]
FROM labels WHERE target.owner=labels.owner AND target.id=labels.root
AND target.redirect_id IS NULL AND target.name IS NULL AND cardinality(labels.names)=1;
