package app.nephos.keycloak;

import java.util.List;
import org.keycloak.Config;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.provider.ProviderConfigProperty;
import org.keycloak.services.clientpolicy.executor.ClientPolicyExecutorProvider;
import org.keycloak.services.clientpolicy.executor.ClientPolicyExecutorProviderFactory;

public final class PersistentLoginPolicyFactory implements ClientPolicyExecutorProviderFactory {
    @Override public ClientPolicyExecutorProvider create(KeycloakSession session) { return new PersistentLoginPolicy(session); }
    @Override public String getId() { return PersistentLoginPolicy.ID; }
    @Override public String getHelpText() { return "Preserve legacy sessions; require same-key DPoP for bound refresh and revocation."; }
    @Override public List<ProviderConfigProperty> getConfigProperties() { return List.of(); }
    @Override public void init(Config.Scope config) {}
    @Override public void postInit(KeycloakSessionFactory factory) {}
    @Override public void close() {}
}
