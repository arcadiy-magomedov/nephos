CREATE INDEX outbox_pending ON outbox(id) WHERE sent_at IS NULL;
