package app.nephos.keycloak;

import org.keycloak.Config;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.protocol.oidc.grants.OAuth2GrantType;
import org.keycloak.protocol.oidc.grants.OAuth2GrantTypeFactory;

public final class LoginPinGrantFactory implements OAuth2GrantTypeFactory {
    @Override public String getId() { return PinSupport.GRANT_TYPE; }
    @Override public String getShortcut() { return "np"; }
    @Override public OAuth2GrantType create(KeycloakSession session) { return new LoginPinGrant(); }
    @Override public void init(Config.Scope config) {}
    @Override public void postInit(KeycloakSessionFactory factory) {}
    @Override public void close() {}
}
