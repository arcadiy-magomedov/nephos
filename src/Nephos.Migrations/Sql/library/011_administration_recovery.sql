ALTER TABLE principals ADD COLUMN administration_denied boolean NOT NULL DEFAULT false;
UPDATE principals SET administration_denied=true WHERE NOT enabled;
ALTER TABLE administration_operations DROP CONSTRAINT administration_operations_status_check;
ALTER TABLE administration_operations ADD CONSTRAINT administration_operations_status_check
    CHECK(status IN ('pending','running','failed','completed','abandoned'));
DROP INDEX administration_active_subject;
CREATE UNIQUE INDEX administration_active_subject ON administration_operations(subject)
    WHERE status NOT IN ('completed','abandoned');
