package app.nephos.keycloak;

import org.keycloak.Config;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.services.resource.RealmResourceProvider;
import org.keycloak.services.resource.RealmResourceProviderFactory;

public final class NephosAdminResourceFactory implements RealmResourceProviderFactory {
    @Override public String getId() { return "nephos-admin"; }
    @Override public RealmResourceProvider create(KeycloakSession session) {
        return new NephosAdminResource(session);
    }
    @Override public void init(Config.Scope config) {}
    @Override public void postInit(KeycloakSessionFactory factory) {}
    @Override public void close() {}
}
