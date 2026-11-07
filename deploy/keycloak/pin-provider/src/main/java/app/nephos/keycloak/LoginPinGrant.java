package app.nephos.keycloak;

import java.util.Collections;
import java.util.Map;
import java.util.Set;

import jakarta.ws.rs.core.Response;
import org.keycloak.OAuth2Constants;
import org.keycloak.OAuthErrorException;
import org.keycloak.events.Errors;
import org.keycloak.events.EventType;
import org.keycloak.models.AuthenticatedClientSessionModel;
import org.keycloak.models.ClientSessionContext;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.protocol.oidc.OIDCLoginProtocol;
import org.keycloak.protocol.oidc.grants.OAuth2GrantTypeBase;
import org.keycloak.services.CorsErrorResponseException;
import org.keycloak.services.managers.AuthenticationManager;
import org.keycloak.authentication.AuthenticationProcessor;
import org.keycloak.services.managers.AuthenticationSessionManager;
import org.keycloak.sessions.AuthenticationSessionModel;
import org.keycloak.sessions.RootAuthenticationSessionModel;

public final class LoginPinGrant extends OAuth2GrantTypeBase {
    @Override
    public Response process(Context context) {
        setContext(context);
        checkClient();
        if (!"nephos-ios".equals(client.getClientId()) || !client.isPublicClient()) {
            return invalidGrant();
        }

        String email = formParams.getFirst("username");
        String pin = formParams.getFirst("pin");
        String deviceId = formParams.getFirst("device_id");
        String deviceName = formParams.getFirst("device_name");
        String nonce = formParams.getFirst("nonce");
        if (email == null || email.length() > 320 || pin == null || !pin.matches("[0-9]{8}")
                || !isUuid(deviceId)
                || deviceName == null || deviceName.isBlank() || deviceName.length() > 100) {
            return invalidGrant();
        }
        if (nonce == null || nonce.isBlank() || nonce.length() > 256) return invalidGrant();

        email = PinSupport.normalizeEmail(email);
        if (email == null) return invalidGrant();
        UserModel user = session.users().getUserByEmail(realm, email);
        if (user == null || !user.isEnabled()) {
            return invalidGrant();
        }

        String lockKey = PinSupport.lockKey(realm.getName(), user.getId());
        var singleUse = session.singleUseObjects();
        if (!singleUse.putIfAbsent(lockKey, 5)) {
            return temporarilyUnavailable();
        }

        try {
            new EnrollmentStore(session).lock();
            user = session.users().getUserById(realm, user.getId());
            if (user == null || !user.isEnabled()) return invalidGrant();
            String attemptsKey = PinSupport.attemptsKey(realm.getName(), user.getId());
            Map<String, String> attempts = singleUse.get(attemptsKey);
            long now = java.time.Instant.now().getEpochSecond();
            long attemptsExpireAt = attempts == null ? now + 15 * 60
                    : Long.parseLong(attempts.getOrDefault("expiresAt", "0"));
            if (attempts != null && attemptsExpireAt <= now) {
                singleUse.remove(attemptsKey);
                attempts = null;
                attemptsExpireAt = now + 15 * 60;
            }
            int count = attempts == null ? 0 : Integer.parseInt(attempts.getOrDefault("count", "0"));
            if (count >= 10) {
                return invalidGrant();
            }
            if (attempts == null) {
                // put() is transactional and rolls back when an invalid grant throws.
                // Reserve immediately, like the lock, so rejected guesses still count.
                if (!singleUse.putIfAbsent(attemptsKey, 15 * 60)) return temporarilyUnavailable();
            }
            if (!singleUse.replace(attemptsKey, Map.of("count", Integer.toString(count + 1),
                    "expiresAt", Long.toString(attemptsExpireAt)))) {
                return temporarilyUnavailable();
            }

            String scope = getRequestedScopes();
            Map<String, String> record = singleUse.get(PinSupport.pinKey(realm.getName(), user.getId()));
            if (record == null || Long.parseLong(record.getOrDefault("expiresAt", "0"))
                    <= java.time.Instant.now().getEpochSecond() || !PinSupport.constantTimeEquals(
                    record.getOrDefault("digest", ""), PinSupport.pinDigest(pin))) {
                return invalidGrant();
            }
            if (singleUse.remove(PinSupport.pinKey(realm.getName(), user.getId())) == null) {
                return invalidGrant();
            }

            RootAuthenticationSessionModel root = new AuthenticationSessionManager(session)
                    .createAuthenticationSession(realm, false);
            AuthenticationSessionModel authSession = root.createAuthenticationSession(client);
            authSession.setProtocol(OIDCLoginProtocol.LOGIN_PROTOCOL);
            authSession.setAction(AuthenticatedClientSessionModel.Action.AUTHENTICATE.name());
            authSession.setClientNote(OIDCLoginProtocol.ISSUER,
                    org.keycloak.services.Urls.realmIssuer(session.getContext().getUri().getBaseUri(), realm.getName()));
            authSession.setClientNote(OIDCLoginProtocol.SCOPE_PARAM, scope);
            authSession.setAuthenticatedUser(user);
            AuthenticationManager.setClientScopesInSession(session, authSession);

            JpaEnrollmentSession enrollment = new JpaEnrollmentSession(session, user, client,
                    java.util.UUID.randomUUID().toString(), deviceName.trim(),
                    new EnrollmentStore(session).epoch(user.getId()));
            UserSessionModel userSession = enrollment.online;
            ClientSessionContext clientSessionCtx = AuthenticationProcessor.attachSession(authSession,
                    userSession, session, realm, clientConnection, event);
            userSession.setNote(PinSupport.DEVICE_ID_NOTE, deviceId.toLowerCase());
            userSession.setNote(PinSupport.DEVICE_NAME_NOTE, deviceName.trim());
            clientSessionCtx.setAttribute(OIDCLoginProtocol.NONCE_PARAM, nonce);
            enrollment.onlineClient.setNote(OIDCLoginProtocol.NONCE_PARAM, nonce);
            enrollment.synchronizeOfflineContext();
            updateUserSessionFromClientAuth(userSession);
            event.user(user).session(userSession).detail("auth_method", "nephos_login_pin");
            Response result = createTokenResponse(user, userSession, clientSessionCtx, scope, false, null);
            enrollment.persistClientChanges();
            QrGrant.prepare(session);
            return result;
        } finally {
            singleUse.remove(lockKey);
        }
    }

    private boolean isUuid(String value) {
        if (value == null) return false;
        try {
            return java.util.UUID.fromString(value).toString().equalsIgnoreCase(value);
        } catch (IllegalArgumentException exception) {
            return false;
        }
    }

    private Response invalidGrant() {
        event.error(Errors.INVALID_USER_CREDENTIALS);
        throw new CorsErrorResponseException(cors, OAuthErrorException.INVALID_GRANT,
                "The account or PIN is invalid or expired.", Response.Status.BAD_REQUEST);
    }

    private Response temporarilyUnavailable() {
        throw new CorsErrorResponseException(cors, OAuthErrorException.TEMPORARILY_UNAVAILABLE,
                "Sign-in is temporarily unavailable. Try again.", Response.Status.SERVICE_UNAVAILABLE);
    }

    @Override public EventType getEventType() { return EventType.LOGIN; }
    @Override public Set<String> getTokenParameterNames() { return Collections.emptySet(); }
}
