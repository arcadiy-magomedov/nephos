DROP INDEX IF EXISTS administration_login_reservation;
CREATE UNIQUE INDEX administration_login_reservation ON administration_operations(lower(login))
    WHERE kind='provision' AND status<>'abandoned';
