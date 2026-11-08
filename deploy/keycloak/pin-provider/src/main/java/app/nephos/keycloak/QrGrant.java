package app.nephos.keycloak;

import java.time.Instant;
import java.util.Map;
import java.util.Set;
import jakarta.ws.rs.core.Response;
import org.keycloak.OAuthErrorException;
import org.keycloak.authentication.AuthenticationProcessor;
import org.keycloak.events.EventType;
import org.keycloak.models.*;
import org.keycloak.models.session.UserSessionPersisterProvider;
import org.keycloak.models.sessions.infinispan.transaction.DefaultInfinispanTransactionProvider;
import org.keycloak.models.sessions.infinispan.transaction.InfinispanTransactionProvider;
import org.keycloak.protocol.oidc.OIDCLoginProtocol;
import org.keycloak.protocol.oidc.grants.OAuth2GrantTypeBase;
import org.keycloak.services.CorsErrorResponseException;
import org.keycloak.services.managers.AuthenticationManager;
import org.keycloak.services.managers.AuthenticationSessionManager;
import org.keycloak.util.JsonSerialization;
import org.keycloak.representations.dpop.DPoP;
import org.keycloak.services.util.DPoPUtil;
import org.keycloak.services.clientpolicy.ClientPolicyException;

public final class QrGrant extends OAuth2GrantTypeBase {
    private static final org.jboss.logging.Logger LOG = org.jboss.logging.Logger.getLogger(QrGrant.class);
    static void prepare(KeycloakSession session) {
        var provider = session.getProvider(InfinispanTransactionProvider.class);
        if (!(provider instanceof DefaultInfinispanTransactionProvider persistent))
            throw new IllegalStateException("Unsupported session transaction provider");
        persistent.prepareStep();
        session.getProvider(org.keycloak.connections.jpa.JpaConnectionProvider.class).getEntityManager().flush();
    }
    @Override public Response process(Context context) {
        setContext(context); checkClient();
        if (!"nephos-ios".equals(client.getClientId()) || !client.isPublicClient()) return fail("invalid_client");
        String stage = "validation";
        try {
            String inviteId = EnrollmentResource.uuid(formParams.getFirst("invite_id"));
            String requestId = EnrollmentResource.uuid(formParams.getFirst("request_id"));
            String challengeId = EnrollmentResource.uuid(formParams.getFirst("challenge_id"));
            String nonce = EnrollmentResource.uuid(formParams.getFirst("nonce"));
            String publicKey = formParams.getFirst("public_key"), signature = formParams.getFirst("signature");
            String secret = formParams.getFirst("invite_secret"), name = formParams.getFirst("device_name");
            if (secret == null || EnrollmentCrypto.decode(secret).length != 32
                    || name == null || name.isBlank() || name.length() > 100
                    || signature == null || signature.length() > 128) return fail("invalid_request");
            String fingerprint = EnrollmentCrypto.fingerprint(publicKey), origin = EnrollmentCrypto.origin();
            EnrollmentStore store = new EnrollmentStore(session); store.lock();
            long now = Instant.now().getEpochSecond();
            var challenge = store.get("challenge:" + challengeId);
            if (challenge == null || challenge.expiresAt <= now) return fail("invalid_proof");
            var proof = store.data(challenge);
            if (!inviteId.equals(proof.get("inviteId")) || !requestId.equals(proof.get("requestId"))
                    || !origin.equals(proof.get("origin")) || !fingerprint.equals(proof.get("fingerprint"))
                    || Boolean.TRUE.equals(proof.get("used"))
                    || !EnrollmentCrypto.verify(publicKey, (String) proof.get("text"), signature))
                return fail("invalid_proof");
            var record = store.get("invite:" + inviteId);
            if (record == null) return fail("invite_unavailable");
            var data = store.data(record);
            if (!EnrollmentCrypto.keyVersion().equals(data.get("keyVersion"))) return fail("session_revoked");
            if (!PinSupport.constantTimeEquals((String) data.get("verifier"), EnrollmentCrypto.digest(secret)))
                return fail("invite_unavailable");
            UserModel user = session.users().getUserById(realm, record.subject);
            if (user == null || !user.isEnabled()) return fail("user_disabled");
            if (store.epoch(record.subject) != EnrollmentStore.number(data, "epoch")) return fail("session_revoked");
            String status = (String) data.get("status");
            if ("cancelled".equals(status)) return fail("invite_cancelled");
            if ("revoked".equals(status)) return fail("session_revoked");
            boolean bound = "used".equals(status) ? data.get("dpopJkt") != null : PersistentLoginPolicy.required(client);
            String dpopJkt = null;
            if (bound) {
                DPoP dpop = session.getAttribute(DPoPUtil.DPOP_SESSION_ATTRIBUTE, DPoP.class);
                if (dpop == null) return proofFailure("dpop_proof_required");
                dpopJkt = EnrollmentCrypto.jwkThumbprint(publicKey);
                if (!dpopJkt.equals(dpop.getThumbprint())
                        || ("used".equals(status) && !dpopJkt.equals(data.get("dpopJkt"))))
                    return proofFailure("dpop_key_mismatch");
                PersistentLoginPolicy.bind(session, client);
            } else if (!"used".equals(status)
                    && session.getAttribute(DPoPUtil.DPOP_SESSION_ATTRIBUTE) != null) {
                return proofFailure("persistent_login_not_enabled");
            }
            String scope = getRequestedScopes();
            if (!Set.of("openid", "offline_access").equals(Set.of(scope.split(" "))))
                return fail("invalid_scope");
            String binding = String.join("\n", inviteId, requestId, fingerprint, origin, client.getClientId(),
                    nonce, name, scope, Long.toString(store.epoch(record.subject)));
            if (bound) binding += "\ndpop:" + dpopJkt;
            proof.put("used", true);
            store.save(challenge.id, challenge.kind, challenge.subject, challenge.expiresAt, proof);
            if ("used".equals(status)) {
                if (!binding.equals(data.get("binding"))) return fail("invite_used");
                if (EnrollmentStore.number(data, "deliveryUntil") <= now || data.get("receipt") == null)
                    return fail("recovery_expired");
                String sessionId = (String) data.get("sessionId");
                var persisted = session.getProvider(UserSessionPersisterProvider.class);
                UserSessionModel offline = persisted.loadUserSession(realm, sessionId, true);
                if (offline == null || !AuthenticationManager.isSessionValid(realm, offline))
                    return fail("session_revoked");
                var clientSession = persisted.loadClientSession(realm, client, offline, true);
                if (clientSession == null || clientSession.getTimestamp() != EnrollmentStore.number(data, "clientTimestamp"))
                    return fail("session_revoked");
                String json = EnrollmentCrypto.crypt((String) data.get("receipt"), binding, false);
                var tokens = JsonSerialization.readValue(json, org.keycloak.representations.AccessTokenResponse.class);
                tokenManager.verifyRefreshToken(session, realm, client, request, tokens.getRefreshToken(), true);
                return Response.ok(tokens).header("Cache-Control", "no-store").build();
            }
            if (record.expiresAt <= now) return fail("invite_expired");
            if (!"active".equals(status)) return fail("invite_unavailable");
            var requestRecord = store.get("request:" + requestId);
            if (requestRecord != null) return fail("invite_used");
            var root = new AuthenticationSessionManager(session).createAuthenticationSession(realm, false);
            var auth = root.createAuthenticationSession(client);
            auth.setProtocol(OIDCLoginProtocol.LOGIN_PROTOCOL);
            auth.setAction(AuthenticatedClientSessionModel.Action.AUTHENTICATE.name());
            auth.setClientNote(OIDCLoginProtocol.ISSUER, origin + "/realms/nephos");
            auth.setClientNote(OIDCLoginProtocol.SCOPE_PARAM, scope);
            auth.setAuthenticatedUser(user);
            AuthenticationManager.setClientScopesInSession(session, auth);
            stage = "create-jpa-session";
            JpaEnrollmentSession enrollment = new JpaEnrollmentSession(session, user, client, requestId,
                    name, store.epoch(record.subject));
            UserSessionModel userSession = enrollment.online;
            ClientSessionContext clientContext = AuthenticationProcessor.attachSession(auth, userSession,
                    session, realm, clientConnection, event);
            userSession.setNote(PinSupport.DEVICE_ID_NOTE, requestId);
            userSession.setNote(PinSupport.DEVICE_NAME_NOTE, name);
            userSession.setNote("nephos.qr.epoch", Long.toString(store.epoch(record.subject)));
            clientContext.setAttribute(OIDCLoginProtocol.NONCE_PARAM, nonce);
            enrollment.onlineClient.setNote(OIDCLoginProtocol.NONCE_PARAM, nonce);
            enrollment.synchronizeOfflineContext();
            updateUserSessionFromClientAuth(userSession);
            event.user(user).session(userSession).detail("auth_method", "nephos_qr");
            stage = "normal-token-response";
            Response response = createTokenResponse(user, userSession, clientContext, scope, false, null);
            enrollment.persistClientChanges();
            stage = "prepare-session-writes";
            prepare(session);
            stage = "verify-durable-sessions";
            var persister = session.getProvider(UserSessionPersisterProvider.class);
            UserSessionModel offline = persister.loadUserSession(realm, userSession.getId(), true);
            if (offline == null || persister.loadUserSession(realm, userSession.getId(), false) == null)
                throw new IllegalStateException("Session writes are not in the enrollment transaction");
            stage = "verify-durable-clients";
            var offlineClient = persister.loadClientSession(realm, client, offline, true);
            if (offlineClient == null || persister.loadClientSession(realm, client, userSession, false) == null)
                throw new IllegalStateException("Client writes are not in the enrollment transaction");
            stage = "serialize-receipt";
            String json = JsonSerialization.writeValueAsString(response.getEntity());
            if (json.length() > 16384) throw new IllegalStateException("Token receipt too large");
            data.put("status", "used"); data.put("binding", binding);
            if (bound) data.put("dpopJkt", dpopJkt);
            data.put("sessionId", userSession.getId()); data.put("deliveryUntil", now + 600);
            data.put("clientTimestamp", offlineClient.getTimestamp());
            data.put("receipt", EnrollmentCrypto.crypt(json, binding, true));
            store.save(record.id, record.kind, record.subject, record.expiresAt, data);
            store.save("request:" + requestId, "request", record.subject, 0, Map.of("inviteId", inviteId));
            store.em.flush();
            return response;
        } catch (CorsErrorResponseException exception) { throw exception; }
        catch (ClientPolicyException exception) {
            throw new CorsErrorResponseException(cors, exception.getError(), exception.getErrorDetail(), exception.getErrorStatus());
        }
        catch (IllegalArgumentException exception) { return fail("invalid_request"); }
        catch (OAuthErrorException exception) { return fail("session_revoked"); }
        catch (Exception exception) {
            LOG.warnf("QR enrollment unavailable at %s (%s)", stage, exception.getClass().getSimpleName());
            session.getTransactionManager().setRollbackOnly();
            throw new CorsErrorResponseException(cors, OAuthErrorException.TEMPORARILY_UNAVAILABLE,
                    "temporarily_unavailable", Response.Status.SERVICE_UNAVAILABLE);
        }
    }
    private Response fail(String code) {
        throw new CorsErrorResponseException(cors, OAuthErrorException.INVALID_GRANT, code, Response.Status.BAD_REQUEST);
    }
    private Response proofFailure(String code) {
        throw new CorsErrorResponseException(cors, "invalid_dpop_proof", code, Response.Status.BAD_REQUEST);
    }
    @Override public EventType getEventType() { return EventType.LOGIN; }
    @Override public Set<String> getTokenParameterNames() {
        return Set.of("invite_secret", "signature");
    }
}
