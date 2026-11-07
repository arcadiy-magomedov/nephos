package app.nephos.keycloak;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import org.keycloak.connections.jpa.JpaConnectionProvider;
import org.keycloak.models.KeycloakSession;
import org.keycloak.util.JsonSerialization;

final class EnrollmentStore {
    final EntityManager em;
    EnrollmentStore(KeycloakSession session) {
        em = session.getProvider(JpaConnectionProvider.class).getEntityManager();
    }
    void lock() {
        em.find(EnrollmentRecord.class, "lock", LockModeType.PESSIMISTIC_WRITE,
                Map.of("jakarta.persistence.lock.timeout", 5000));
    }
    EnrollmentRecord get(String id) { return em.find(EnrollmentRecord.class, id); }
    Map<String, Object> data(EnrollmentRecord record) {
        try {
            if (record == null) return new LinkedHashMap<>();
            return new LinkedHashMap<>(JsonSerialization.readValue(record.payload, Map.class));
        } catch (java.io.IOException exception) { throw new IllegalStateException(exception); }
    }
    void save(String id, String kind, String subject, long expiry, Map<String, Object> data) {
        EnrollmentRecord record = get(id);
        boolean created = record == null;
        if (record == null) {
            record = new EnrollmentRecord();
            record.id = id;
        }
        record.kind = kind;
        record.subject = subject;
        record.expiresAt = expiry;
        try { record.payload = JsonSerialization.writeValueAsString(data); }
        catch (java.io.IOException exception) { throw new IllegalStateException(exception); }
        if (created) em.persist(record);
    }
    List<EnrollmentRecord> records(String subject, String kind) {
        return em.createQuery("from EnrollmentRecord where subject = :subject and kind = :kind order by id",
                EnrollmentRecord.class).setParameter("subject", subject).setParameter("kind", kind)
                .getResultList();
    }
    long epoch(String subject) { return number(data(get("user:" + subject)), "epoch"); }
    long revision(String subject) { return number(data(get("user:" + subject)), "revision"); }
    static long number(Map<String, Object> data, String key) {
        return ((Number) data.getOrDefault(key, 0L)).longValue();
    }
    void fence(String subject, boolean advanceEpoch) {
        Map<String, Object> state = data(get("user:" + subject));
        state.put("epoch", epoch(subject) + (advanceEpoch ? 1 : 0));
        state.put("revision", revision(subject) + 1);
        save("user:" + subject, "user", subject, 0, state);
        if (advanceEpoch) {
            for (EnrollmentRecord record : records(subject, "invite")) {
                Map<String, Object> invite = data(record);
                invite.put("status", "revoked");
                invite.remove("receipt");
                save(record.id, record.kind, subject, record.expiresAt, invite);
            }
        }
    }
    void invalidateSession(String sessionId) {
        for (EnrollmentRecord record : em.createQuery("from EnrollmentRecord where kind = 'invite'",
                EnrollmentRecord.class).getResultList()) {
            Map<String, Object> data = data(record);
            if (sessionId.equals(data.get("sessionId"))) {
                data.remove("receipt");
                data.put("status", "revoked");
                save(record.id, record.kind, record.subject, record.expiresAt, data);
            }
        }
    }
    void cleanup(long now) {
        em.createQuery("delete from EnrollmentRecord where kind in ('challenge','rate') and expiresAt < :now")
                .setParameter("now", now).executeUpdate();
        for (EnrollmentRecord record : em.createQuery(
                "from EnrollmentRecord where kind = 'invite' and expiresAt < :now", EnrollmentRecord.class)
                .setParameter("now", now).getResultList()) {
            Map<String, Object> data = data(record);
            if (number(data, "deliveryUntil") <= now && data.remove("receipt") != null)
                save(record.id, record.kind, record.subject, record.expiresAt, data);
        }
    }
}
