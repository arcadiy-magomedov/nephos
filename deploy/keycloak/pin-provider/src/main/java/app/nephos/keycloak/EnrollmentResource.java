package app.nephos.keycloak;

import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import jakarta.ws.rs.*;
import jakarta.ws.rs.core.*;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.UserModel;
import org.keycloak.util.JsonSerialization;

@Produces(MediaType.APPLICATION_JSON)
public class EnrollmentResource {
    private final KeycloakSession session;
    private final EnrollmentStore store;
    EnrollmentResource(KeycloakSession session) { this.session = session; store = new EnrollmentStore(session); }
    static String uuid(Object value) {
        if (!(value instanceof String text) || !UUID.fromString(text).toString().equals(text))
            throw new IllegalArgumentException("invalid_request");
        return text;
    }
    static Map<String, Object> input(InputStream body) {
        try {
            byte[] bytes = body.readNBytes(4097);
            if (bytes.length > 4096) throw new IllegalArgumentException("invalid_request");
            return JsonSerialization.readValue(bytes, Map.class);
        } catch (java.io.IOException exception) { throw new IllegalArgumentException("invalid_request"); }
    }
    static Response response(int status, Object body) {
        return Response.status(status).entity(body).header("Cache-Control", "no-store").build();
    }
    static Response failure(int status, String error) { return response(status, Map.of("error", error)); }
    private UserModel user(String subject) {
        return session.users().getUserById(session.getContext().getRealm(), uuid(subject));
    }
    private void auth(HttpHeaders headers) {
        if (!NephosAdminResource.authorized(headers, session)) throw new NotAuthorizedException("identity-service");
    }
    Map<String, Object> identity(UserModel user) {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("subject", user.getId()); result.put("login", user.getUsername());
        result.put("displayName", user.getFirstName() == null ? user.getUsername() : user.getFirstName());
        result.put("enabled", user.isEnabled()); result.put("revision", store.revision(user.getId()));
        result.put("epoch", store.epoch(user.getId()));
        result.put("commandId", user.getFirstAttribute("nephos.provision.command"));
        return result;
    }
    @GET @Path("enrollment/config")
    public Response config() {
        String origin = EnrollmentCrypto.origin();
        return response(200, Map.of("v", 1, "origin", origin, "issuer", origin + "/realms/nephos",
                "clientId", "nephos-ios", "grantType", QrGrantFactory.ID));
    }
    @POST @Path("enrollment/challenge") @Consumes(MediaType.APPLICATION_JSON)
    public Response challenge(InputStream body) {
        try {
            var data = input(body);
            if (data.size() != 4 || !"nephos-ios".equals(data.get("clientId"))) return failure(400, "invalid_request");
            String inviteId = uuid(data.get("inviteId")), requestId = uuid(data.get("requestId"));
            String key = (String) data.get("publicKey");
            String fingerprint = EnrollmentCrypto.fingerprint(key);
            String origin = EnrollmentCrypto.origin();
            store.lock();
            long now = Instant.now().getEpochSecond();
            store.cleanup(now);
            String rateId = "rate:" + EnrollmentCrypto.digest(session.getContext().getConnection().getRemoteAddr())
                    + ":" + now / 60;
            Map<String, Object> rate = store.data(store.get(rateId));
            long count = EnrollmentStore.number(rate, "count");
            if (count >= 30) return failure(429, "rate_limited");
            store.save(rateId, "rate", null, now + 120, Map.of("count", count + 1));
            if (store.get("invite:" + inviteId) == null) return failure(400, "invite_unavailable");
            String id = UUID.randomUUID().toString();
            String text = String.join("\n", "nephos-qr-v1", origin, "nephos-ios", inviteId,
                    requestId, fingerprint, id, EnrollmentCrypto.random());
            store.save("challenge:" + id, "challenge", null, now + 60,
                    Map.of("inviteId", inviteId, "requestId", requestId, "fingerprint", fingerprint,
                            "text", text, "origin", origin));
            return response(200, Map.of("challengeId", id,
                    "challenge", EnrollmentCrypto.encode(text.getBytes(StandardCharsets.UTF_8)), "expiresIn", 60));
        } catch (IllegalArgumentException exception) { return failure(400, "invalid_request"); }
    }
    @PUT @Path("users/{subject}/provision") @Consumes(MediaType.APPLICATION_JSON)
    public Response provision(@PathParam("subject") String subject, InputStream body, @Context HttpHeaders headers) {
        auth(headers);
        try {
            subject = uuid(subject); var data = input(body);
            String command = uuid(data.get("commandId"));
            String hash = (String) data.get("requestHash"), login = (String) data.get("login");
            String display = (String) data.get("displayName");
            if (hash == null || !hash.matches("[a-f0-9]{64}") || login == null
                    || !login.matches("[a-z0-9][a-z0-9._-]{0,63}") || display == null
                    || display.isBlank() || display.length() > 100) return failure(400, "invalid_request");
            store.lock();
            var provenance = store.get("provision:" + command);
            if (provenance != null && !subject.equals(provenance.subject))
                return failure(409, "command_conflict");
            UserModel existing = user(subject);
            if (existing != null) {
                if (!command.equals(existing.getFirstAttribute("nephos.provision.command"))
                        || !hash.equals(existing.getFirstAttribute("nephos.provision.hash"))
                        || !login.equals(existing.getUsername())) return failure(409, "identity_conflict");
                return response(200, identity(existing));
            }
            if (session.users().getUserByUsername(session.getContext().getRealm(), login) != null)
                return failure(409, "login_conflict");
            UserModel created = session.users().addUser(session.getContext().getRealm(), subject, login, false, false);
            var offlineRole = session.getContext().getRealm().getRole("offline_access");
            if (offlineRole == null) throw new IllegalStateException("Missing offline_access realm role");
            created.grantRole(offlineRole);
            created.setEnabled(false); created.setFirstName(display);
            created.setSingleAttribute("nephos.provision.command", command);
            created.setSingleAttribute("nephos.provision.hash", hash);
            store.fence(subject, false);
            store.save("provision:" + command, "command", subject, 0, Map.of("hash", hash));
            return response(201, identity(created));
        } catch (IllegalArgumentException exception) { return failure(400, "invalid_request"); }
    }
    @GET @Path("users/{subject}")
    public Response get(@PathParam("subject") String subject, @Context HttpHeaders headers) {
        auth(headers); UserModel user = user(subject);
        return user == null ? failure(404, "user_not_found") : response(200, identity(user));
    }
    @GET @Path("users")
    public Response users(@QueryParam("cursor") String cursor, @QueryParam("limit") @DefaultValue("100") int limit,
                          @Context HttpHeaders headers) {
        auth(headers);
        if (limit < 1 || limit > 200) return failure(400, "invalid_request");
        String after = cursor == null || cursor.isEmpty() ? "" : uuid(cursor);
        var realm = session.getContext().getRealm();
        var ids = store.em.createNativeQuery(
                "SELECT ID FROM USER_ENTITY WHERE REALM_ID = :realm AND SERVICE_ACCOUNT_CLIENT_LINK IS NULL"
                        + " AND ID > :after ORDER BY ID")
                .setParameter("realm", realm.getId()).setParameter("after", after).setMaxResults(limit + 1).getResultList();
        var result = new java.util.ArrayList<Map<String, Object>>();
        for (Object id : ids.subList(0, Math.min(limit, ids.size()))) {
            UserModel user = session.users().getUserById(realm, id.toString());
            if (user != null) result.add(identity(user));
        }
        long total = ((Number) store.em.createNativeQuery(
                "SELECT COUNT(*) FROM USER_ENTITY WHERE REALM_ID = :realm AND SERVICE_ACCOUNT_CLIENT_LINK IS NULL")
                .setParameter("realm", realm.getId()).getSingleResult()).longValue();
        var response = new LinkedHashMap<String, Object>();
        response.put("items", result); response.put("total", total);
        response.put("nextCursor", ids.size() > limit ? ids.get(limit - 1).toString() : null);
        return response(200, response);
    }
    @PUT @Path("users/{subject}/profile") @Consumes(MediaType.APPLICATION_JSON)
    public Response profile(@PathParam("subject") String subject, InputStream body, @Context HttpHeaders headers) {
        return mutate(subject, input(body), headers, false);
    }
    @PUT @Path("users/{subject}/access") @Consumes(MediaType.APPLICATION_JSON)
    public Response access(@PathParam("subject") String subject, InputStream body, @Context HttpHeaders headers) {
        return mutate(subject, input(body), headers, true);
    }
    private Response mutate(String subject, Map<String, Object> data, HttpHeaders headers, boolean access) {
        auth(headers);
        try {
            String command = uuid(data.get("commandId")); subject = uuid(subject);
            String id = (access ? "access:" : "profile:") + command;
            String hash = EnrollmentCrypto.digest(subject + "\n" + JsonSerialization.writeValueAsString(
                    new java.util.TreeMap<>(data)));
            store.lock();
            EnrollmentRecord previous = store.get(id);
            UserModel user = user(subject);
            if (user == null) return failure(404, "user_not_found");
            if (previous != null) return hash.equals(store.data(previous).get("hash"))
                    ? response(200, identity(user)) : failure(409, "command_conflict");
            if (!(data.get("expectedRevision") instanceof Number)
                    || EnrollmentStore.number(data, "expectedRevision") != store.revision(subject))
                return failure(409, "revision_conflict");
            if (access) {
                if (!(data.get("enabled") instanceof Boolean enabled)) return failure(400, "invalid_request");
                user.setEnabled(enabled);
                store.fence(subject, !enabled);
                if (!enabled) {
                    session.singleUseObjects().remove(PinSupport.pinKey("nephos", subject));
                    try (var online = session.sessions().getUserSessionsStream(session.getContext().getRealm(), user);
                         var offline = session.sessions().getOfflineUserSessionsStream(session.getContext().getRealm(), user)) {
                        online.toList().forEach(item -> session.sessions().removeUserSession(session.getContext().getRealm(), item));
                        offline.toList().forEach(item -> session.sessions().removeOfflineUserSession(session.getContext().getRealm(), item));
                    }
                    QrGrant.prepare(session);
                }
            } else {
                if (!(data.get("displayName") instanceof String display) || display.isBlank()
                        || display.length() > 100) return failure(400, "invalid_request");
                user.setFirstName(display); store.fence(subject, false);
            }
            store.save(id, "command", subject, 0, Map.of("hash", hash));
            return response(200, identity(user));
        } catch (java.io.IOException | IllegalArgumentException exception) { return failure(400, "invalid_request"); }
    }
    private Map<String, Object> metadata(EnrollmentRecord record) {
        var data = store.data(record);
        String status = (String) data.get("status");
        if ("active".equals(status) && record.expiresAt <= Instant.now().getEpochSecond()) status = "expired";
        return Map.of("inviteId", data.get("inviteId"), "status", status,
                "createdAt", data.get("createdAt"), "expiresAt", Instant.ofEpochSecond(record.expiresAt).toString());
    }
    @POST @Path("users/{subject}/invitations") @Consumes(MediaType.APPLICATION_JSON)
    public Response issue(@PathParam("subject") String subject, InputStream body, @Context HttpHeaders headers) {
        auth(headers);
        try {
            var input = input(body);
            if (input.size() != 1) return failure(400, "invalid_request");
            String command = uuid(input.get("commandId")); subject = uuid(subject);
            String origin = EnrollmentCrypto.origin();
            EnrollmentCrypto.crypt("configuration-check", "check", true);
            store.lock();
            UserModel user = user(subject);
            if (user == null) return failure(404, "user_not_found");
            var previous = store.get("issue:" + command);
            if (previous != null) {
                if (!subject.equals(previous.subject)) return failure(409, "command_conflict");
                return response(200, metadata(store.get("invite:" + store.data(previous).get("inviteId"))));
            }
            if (!user.isEnabled()) return failure(409, "user_disabled");
            long now = Instant.now().getEpochSecond(); store.cleanup(now);
            long active = store.records(subject, "invite").stream().filter(record ->
                    record.expiresAt > now && "active".equals(store.data(record).get("status"))).count();
            if (active >= 10) return failure(429, "rate_limited");
            String invite = UUID.randomUUID().toString(), secret = EnrollmentCrypto.random();
            Map<String, Object> data = new LinkedHashMap<>(Map.of("inviteId", invite, "status", "active",
                    "verifier", EnrollmentCrypto.digest(secret), "epoch", store.epoch(subject),
                    "createdAt", Instant.ofEpochSecond(now).toString(),
                    "keyVersion", EnrollmentCrypto.keyVersion()));
            store.save("invite:" + invite, "invite", subject, now + 600, data);
            store.save("issue:" + command, "command", subject, 0, Map.of("inviteId", invite));
            var response = new LinkedHashMap<>(metadata(store.get("invite:" + invite)));
            response.put("qr", Map.of("v", 1, "origin", origin, "inviteId", invite, "secret", secret));
            return response(201, response);
        } catch (IllegalArgumentException exception) { return failure(400, "invalid_request"); }
    }
    @GET @Path("users/{subject}/invitations")
    public Response list(@PathParam("subject") String subject, @Context HttpHeaders headers) {
        auth(headers); subject = uuid(subject);
        return response(200, Map.of("invitations", store.records(subject, "invite").stream().map(this::metadata).toList()));
    }
    @DELETE @Path("users/{subject}/invitations/{invite}")
    public Response cancel(@PathParam("subject") String subject, @PathParam("invite") String invite,
                           @Context HttpHeaders headers) {
        auth(headers); store.lock();
        var record = store.get("invite:" + uuid(invite));
        if (record == null || !uuid(subject).equals(record.subject)) return failure(404, "invite_not_found");
        var data = store.data(record);
        data.remove("receipt"); data.put("status", "cancelled");
        store.save(record.id, record.kind, record.subject, record.expiresAt, data);
        return response(200, metadata(record));
    }
}
