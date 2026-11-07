package app.nephos.keycloak;

import java.security.MessageDigest;
import java.io.InputStream;
import java.io.IOException;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Map;
import java.util.UUID;
import java.util.stream.Stream;

import jakarta.ws.rs.DELETE;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.Context;
import jakarta.ws.rs.core.HttpHeaders;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.services.resource.RealmResourceProvider;

public final class NephosAdminResource extends EnrollmentResource implements RealmResourceProvider {
    private static final String REALM = "nephos";
    private final KeycloakSession session;

    NephosAdminResource(KeycloakSession session) {
        super(session);
        this.session = session;
    }

    @Override public Object getResource() { return this; }
    @Override public void close() {}


    @POST
    @Path("request-pin")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public Response requestPin(InputStream body) {
        try {
            new EnrollmentStore(session).lock();
            var singleUse = session.singleUseObjects();
            String ip = session.getContext().getConnection().getRemoteAddr();
            boolean allowed = false;
            for (int slot = 0; slot < 10; slot++) {
                if (singleUse.putIfAbsent(PinSupport.requestKey("ip", ip + ":" + slot), 60)) {
                    allowed = true;
                    break;
                }
            }
            if (!allowed) return failure(429, "rate_limited");
            Map<?, ?> input;
            try {
                byte[] bytes = body.readNBytes(1025);
                if (bytes.length > 1024) return failure(400, "invalid_request");
                input = org.keycloak.util.JsonSerialization.readValue(bytes, Map.class);
            } catch (IOException | IllegalArgumentException exception) {
                return failure(400, "invalid_request");
            }
            if (input == null || input.size() != 2 || !"nephos-ios".equals(input.get("clientId"))
                    || !(input.get("email") instanceof String)) return failure(400, "invalid_request");
            String email = PinSupport.normalizeEmail((String) input.get("email"));
            if (email == null) return failure(400, "invalid_email");
            var client = session.getContext().getRealm().getClientByClientId("nephos-ios");
            if (client == null || !client.isEnabled() || !client.isPublicClient()) {
                return failure(400, "invalid_client");
            }
            UserModel user = session.users().getUserByEmail(session.getContext().getRealm(), email);
            if (user == null || !user.isEnabled()) return failure(404, "account_unavailable");
            String lock = PinSupport.lockKey(REALM, user.getId());
            if (!singleUse.putIfAbsent(lock, 5)) return failure(503, "temporarily_unavailable");
            try {
                user = findUser(user.getId());
                if (user == null || !user.isEnabled()) return failure(404, "account_unavailable");
                String key = PinSupport.pinKey(REALM, user.getId());
                Map<String, String> record = singleUse.get(key);
                long now = Instant.now().getEpochSecond();
                if (record != null && record.containsKey("cipher")) {
                    long remaining = Long.parseLong(record.get("expiresAt")) - now;
                    if (remaining > 0) return publicReceipt(remaining);
                }
                // Resuming an accepted request neither issues a PIN nor extends its lifetime.
                // Only new issuance consumes the email cooldown; the IP budget covers every request.
                if (!singleUse.putIfAbsent(PinSupport.requestKey("email", REALM + ":" + email), 60)) {
                    return failure(429, "rate_limited");
                }
                String pin = PinSupport.newPin();
                singleUse.put(key, PinSupport.PIN_TTL_SECONDS, Map.of(
                        "digest", PinSupport.pinDigest(pin),
                        "cipher", PinSupport.encryptPin(pin, key),
                        "expiresAt", Long.toString(now + PinSupport.PIN_TTL_SECONDS)));
                return publicReceipt(PinSupport.PIN_TTL_SECONDS);
            } finally {
                singleUse.remove(lock);
            }
        } catch (RuntimeException exception) {
            return failure(503, "temporarily_unavailable");
        }
    }

    @GET
    @Path("pin-requests")
    @Produces(MediaType.APPLICATION_JSON)
    public Response pinRequests(@Context HttpHeaders headers) {
        if (!authorized(headers)) return failure(401, "unauthorized");
        var requests = new ArrayList<Map<String, Object>>();
        try (Stream<UserModel> users = session.users().searchForUserStream(
                session.getContext().getRealm(), Map.of(), null, null)) {
            var singleUse = session.singleUseObjects();
            for (var iterator = users.iterator(); iterator.hasNext();) {
                UserModel user = iterator.next();
                String key = PinSupport.pinKey(REALM, user.getId());
                Map<String, String> record = singleUse.get(key);
                if (record == null || !record.containsKey("cipher")) continue;
                String lock = PinSupport.lockKey(REALM, user.getId());
                if (!singleUse.putIfAbsent(lock, 5)) return failure(503, "temporarily_unavailable");
                try {
                    user = findUser(user.getId());
                    record = singleUse.get(key);
                    if (record == null || !record.containsKey("cipher")) continue;
                    long expiresAt = Long.parseLong(record.get("expiresAt"));
                    if (user == null || !user.isEnabled() || expiresAt <= Instant.now().getEpochSecond()) {
                        singleUse.remove(key);
                        continue;
                    }
                    String pin = PinSupport.decryptPin(record.get("cipher"), key);
                    if (!PinSupport.constantTimeEquals(record.get("digest"), PinSupport.pinDigest(pin))) {
                        return failure(503, "temporarily_unavailable");
                    }
                    requests.add(Map.of("email", user.getEmail(), "username", user.getUsername(),
                            "pin", pin, "expiresAt", Instant.ofEpochSecond(expiresAt).toString()));
                } finally {
                    singleUse.remove(lock);
                }
            }
            return Response.ok(Map.of("requests", requests)).header("Cache-Control", "no-store").build();
        } catch (RuntimeException exception) {
            return failure(503, "temporarily_unavailable");
        }
    }

    private Response publicReceipt(long expiresIn) {
        return Response.ok(Map.of("expiresIn", expiresIn)).header("Cache-Control", "no-store").build();
    }

    static Response failure(int status, String error) {
        Response.ResponseBuilder response = Response.status(status).entity(Map.of("error", error))
                .header("Cache-Control", "no-store");
        if (status == 429) response.header("Retry-After", "60");
        return response.build();
    }

    @POST
    @Path("users/{userId}/pin")
    @Produces(MediaType.APPLICATION_JSON)
    public Response issuePin(@PathParam("userId") String userId, @Context HttpHeaders headers) {
        if (!authorized(headers)) return Response.status(Response.Status.UNAUTHORIZED).build();
        new EnrollmentStore(session).lock();
        UserModel user = findUser(userId);
        if (user == null || !user.isEnabled()) return Response.status(Response.Status.NOT_FOUND).build();
        var singleUse = session.singleUseObjects();
        String lock = PinSupport.lockKey(REALM, user.getId());
        if (!singleUse.putIfAbsent(lock, 5)) return Response.status(Response.Status.SERVICE_UNAVAILABLE).build();
        try {
            user = findUser(user.getId());
            if (user == null || !user.isEnabled()) return Response.status(Response.Status.NOT_FOUND).build();
            Map<String, String> previous = singleUse.get(PinSupport.pinKey(REALM, user.getId()));
            String pin = PinSupport.newPin();
            while (previous != null && PinSupport.constantTimeEquals(
                    previous.getOrDefault("digest", ""), PinSupport.pinDigest(pin))) {
                pin = PinSupport.newPin();
            }
            singleUse.put(PinSupport.pinKey(REALM, user.getId()), PinSupport.PIN_TTL_SECONDS,
                    Map.of("digest", PinSupport.pinDigest(pin),
                            "expiresAt", Long.toString(Instant.now().getEpochSecond() + PinSupport.PIN_TTL_SECONDS)));
            return Response.ok(Map.of("pin", pin, "expiresIn", PinSupport.PIN_TTL_SECONDS)).build();
        } finally {
            singleUse.remove(lock);
        }
    }

    @DELETE
    @Path("users/{userId}/pin")
    public Response revokePin(@PathParam("userId") String userId, @Context HttpHeaders headers) {
        if (!authorized(headers)) return Response.status(Response.Status.UNAUTHORIZED).build();
        UserModel user = findUser(userId);
        if (user == null) return Response.status(Response.Status.NOT_FOUND).build();
        var singleUse = session.singleUseObjects();
        String lock = PinSupport.lockKey(REALM, user.getId());
        if (!singleUse.putIfAbsent(lock, 5)) return Response.status(Response.Status.SERVICE_UNAVAILABLE).build();
        try {
            singleUse.remove(PinSupport.pinKey(REALM, user.getId()));
            return Response.noContent().build();
        } finally {
            singleUse.remove(lock);
        }
    }

    @GET
    @Path("users/{userId}/devices")
    @Produces(MediaType.APPLICATION_JSON)
    public Response devices(@PathParam("userId") String userId, @Context HttpHeaders headers) {
        if (!authorized(headers)) return Response.status(Response.Status.UNAUTHORIZED).build();
        UserModel user = findUser(userId);
        if (user == null) return Response.status(Response.Status.NOT_FOUND).build();
        var sessions = new java.util.LinkedHashMap<String, Map<String, Object>>();
        try (Stream<UserSessionModel> online = session.sessions().getUserSessionsStream(session.getContext().getRealm(), user);
             Stream<UserSessionModel> offline = session.sessions().getOfflineUserSessionsStream(session.getContext().getRealm(), user)) {
            Stream.concat(online, offline).forEach(item ->
                    sessions.put(item.getId(), Map.of(
                            "id", item.getId(),
                            "name", item.getNote(PinSupport.DEVICE_NAME_NOTE) == null
                                    ? "Browser / passkey" : item.getNote(PinSupport.DEVICE_NAME_NOTE),
                            "lastAccess", java.time.Instant.ofEpochSecond(item.getLastSessionRefresh()).toString())));
        }
        return Response.ok(Map.of("devices", sessions.values())).build();
    }

    @DELETE
    @Path("users/{userId}/devices/{sessionId}")
    public Response revokeDevice(@PathParam("userId") String userId,
                                 @PathParam("sessionId") String sessionId,
                                 @Context HttpHeaders headers) {
        if (!authorized(headers)) return Response.status(Response.Status.UNAUTHORIZED).build();
        EnrollmentStore store = new EnrollmentStore(session);
        store.lock();
        UserModel user = findUser(userId);
        if (user == null) return Response.status(Response.Status.NOT_FOUND).build();
        UserSessionModel target = findDeviceSession(user, sessionId);
        if (target == null) return Response.status(Response.Status.NOT_FOUND).build();
        store.invalidateSession(sessionId);
        UserSessionModel online = session.sessions().getUserSession(session.getContext().getRealm(), sessionId);
        UserSessionModel offline = session.sessions().getOfflineUserSession(session.getContext().getRealm(), sessionId);
        if (online != null) session.sessions().removeUserSession(session.getContext().getRealm(), online);
        if (offline != null) session.sessions().removeOfflineUserSession(session.getContext().getRealm(), offline);
        QrGrant.prepare(session);
        return Response.noContent().build();
    }

    private UserModel findUser(String id) {
        try {
            return session.users().getUserById(session.getContext().getRealm(), UUID.fromString(id).toString());
        } catch (IllegalArgumentException exception) {
            return null;
        }
    }

    private UserSessionModel findDeviceSession(UserModel user, String id) {
        try (Stream<UserSessionModel> online = session.sessions().getUserSessionsStream(session.getContext().getRealm(), user);
             Stream<UserSessionModel> offline = session.sessions().getOfflineUserSessionsStream(session.getContext().getRealm(), user)) {
            return Stream.concat(online, offline)
                    .filter(item -> item.getId().equals(id)).findFirst().orElse(null);
        }
    }

    private boolean isDeviceSession(UserSessionModel userSession) {
        return userSession.getNote(PinSupport.DEVICE_ID_NOTE) != null
                && userSession.getAuthenticatedClientSessions() != null
                && userSession.getAuthenticatedClientSessions().values().stream()
                .anyMatch(clientSession -> "nephos-ios".equals(clientSession.getClient().getClientId()));
    }

    private boolean authorized(HttpHeaders headers) { return authorized(headers, session); }

    static boolean authorized(HttpHeaders headers, KeycloakSession session) {
        String expected = System.getenv("IDENTITY_ADMIN_SERVICE_KEY");
        String provided = headers.getHeaderString("X-Nephos-Identity-Service-Key");
        return expected != null && expected.length() >= 32 && provided != null
                && "nephos".equals(session.getContext().getRealm().getName())
                && MessageDigest.isEqual(expected.getBytes(java.nio.charset.StandardCharsets.UTF_8),
                provided.getBytes(java.nio.charset.StandardCharsets.UTF_8));
    }
}
