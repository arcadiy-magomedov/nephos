package app.nephos.keycloak;

import org.keycloak.Config;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.protocol.oidc.grants.OAuth2GrantType;
import org.keycloak.protocol.oidc.grants.OAuth2GrantTypeFactory;

public final class QrGrantFactory implements OAuth2GrantTypeFactory {
    public static final String ID = "urn:nephos:params:oauth:grant-type:qr";
    @Override public OAuth2GrantType create(KeycloakSession session) { return new QrGrant(); }
    @Override public String getId() { return ID; }
    @Override public String getShortcut() { return "nq"; }
    @Override public void init(Config.Scope config) {}
    @Override public void postInit(KeycloakSessionFactory factory) {}
    @Override public void close() {}
}
