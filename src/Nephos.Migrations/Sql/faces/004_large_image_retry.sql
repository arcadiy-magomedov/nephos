-- Reattempt decode failures once after expanding the bounded image decoder.
-- Completed observations and manual identities/corrections are left untouched.
UPDATE jobs SET status='queued',attempts=0,error=NULL,available_at=now(),
    lease_token=NULL,lease_until=NULL
WHERE status='error' AND error IN ('inference_rejected','invalid_provenance');
