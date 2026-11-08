package app.nephos.keycloak;

import org.keycloak.OAuthErrorException;
import org.keycloak.common.Profile;
import org.keycloak.models.ClientModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.protocol.oidc.OIDCAdvancedConfigWrapper;
import org.keycloak.representations.RefreshToken;
import org.keycloak.representations.dpop.DPoP;
import org.keycloak.representations.idm.ClientPolicyExecutorConfigurationRepresentation;
import org.keycloak.services.clientpolicy.ClientPolicyContext;
import org.keycloak.services.clientpolicy.ClientPolicyException;
import org.keycloak.services.clientpolicy.context.TokenRefreshContext;
import org.keycloak.services.clientpolicy.context.TokenRevokeContext;
import org.keycloak.services.clientpolicy.executor.ClientPolicyExecutorProvider;
import org.keycloak.services.clientpolicy.executor.DPoPBindEnforcerExecutor;
import org.keycloak.services.util.DPoPUtil;

/** Compatibility gate around Keycloak's refresh-only DPoP executor, not a token issuer. */
public final class PersistentLoginPolicy
        implements ClientPolicyExecutorProvider<ClientPolicyExecutorConfigurationRepresentation> {
    static final String ID = "nephos-persistent-login";
    static final String REQUIRED = "nephos.qr.dpop.required";
    private final KeycloakSession session;

    PersistentLoginPolicy(KeycloakSession session) { this.session = session; }
    @Override public String getProviderId() { return ID; }

    static boolean required(ClientModel client) {
        return "true".equals(client.getAttribute(REQUIRED));
    }

    static void checkConfiguration(KeycloakSession session, ClientModel client) throws ClientPolicyException {
        var realm = session.getContext().getRealm();
        if (!Profile.isFeatureEnabled(Profile.Feature.DPOP) || !client.isPublicClient()
                || OIDCAdvancedConfigWrapper.fromClientModel(client).isUseDPoP()
                || realm.isRevokeRefreshToken() || realm.getOfflineSessionIdleTimeout() != 180 * 24 * 60 * 60
                || realm.isOfflineSessionMaxLifespanEnabled()
                || realm.getClientOfflineSessionIdleTimeout() > 0
                || positive(client.getAttribute("client.offline.session.idle.timeout"))
                || positive(client.getAttribute("client.offline.session.max.lifespan"))) {
            throw new ClientPolicyException(OAuthErrorException.TEMPORARILY_UNAVAILABLE,
                    "persistent_login_configuration", jakarta.ws.rs.core.Response.Status.SERVICE_UNAVAILABLE);
        }
    }

    private static boolean positive(String value) {
        if (value == null || value.isBlank()) return false;
        try { return Long.parseLong(value) > 0; }
        catch (NumberFormatException exception) { return true; }
    }

    static void bind(KeycloakSession session, ClientModel client) throws ClientPolicyException {
        checkConfiguration(session, client);
        var executor = executor(session);
        // The upstream pre-generation hook sets DPOP_BINDING_ONLY_REFRESH_TOKEN_SESSION_ATTRIBUTE.
        // A response policy hook runs too late: both access and refresh tokens already exist then.
        executor.executeOnEvent(new TokenRefreshContext(null, client, null));
    }

    private static DPoPBindEnforcerExecutor executor(KeycloakSession session) {
        var executor = new DPoPBindEnforcerExecutor(session);
        var config = new DPoPBindEnforcerExecutor.Configuration();
        config.setAutoConfigure(false);
        config.setAllowOnlyRefreshTokenBinding(true);
        config.setEnforceAuthorizationCodeBindingToDpop(false);
        executor.setupConfiguration(config);
        return executor;
    }

    @Override public void executeOnEvent(ClientPolicyContext context) throws ClientPolicyException {
        ClientModel client = session.getContext().getClient();
        if (client == null || !"nephos-ios".equals(client.getClientId())) return;
        if (context instanceof TokenRefreshContext refresh) {
            RefreshToken token = session.tokens().decode(refresh.getParams().getFirst("refresh_token"), RefreshToken.class);
            if (token == null || !client.getClientId().equals(token.getIssuedFor())) return;
            if (token.isExpired())
                throw new ClientPolicyException(OAuthErrorException.INVALID_GRANT, "Refresh token expired");
            var cnf = token.getConfirmation();
            DPoP proof = session.getAttribute(DPoPUtil.DPOP_SESSION_ATTRIBUTE, DPoP.class);
            if (cnf == null || cnf.getKeyThumbprint() == null) {
                // A bearer credential alone cannot authorize adoption of a new key.
                if (proof != null) throw new ClientPolicyException("invalid_dpop_proof", "legacy_session_unbound");
                return;
            }
            if (proof == null) throw new ClientPolicyException("invalid_dpop_proof", "dpop_proof_required");
            if (!cnf.getKeyThumbprint().equals(proof.getThumbprint()))
                throw new ClientPolicyException("invalid_dpop_proof", "dpop_key_mismatch");
            bind(session, client);
        } else if (context instanceof TokenRevokeContext revoke) {
            var token = session.tokens().decode(revoke.getParams().getFirst("token"), RefreshToken.class);
            if (token != null && client.getClientId().equals(token.getIssuedFor())
                    && token.getConfirmation() != null && token.getConfirmation().getKeyThumbprint() != null) {
                executor(session).executeOnEvent(context);
            }
        }
    }
}
