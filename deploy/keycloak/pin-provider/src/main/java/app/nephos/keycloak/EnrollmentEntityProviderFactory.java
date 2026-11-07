package app.nephos.keycloak;

import java.util.List;
import org.keycloak.Config;
import org.keycloak.connections.jpa.entityprovider.JpaEntityProvider;
import org.keycloak.connections.jpa.entityprovider.JpaEntityProviderFactory;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;

public final class EnrollmentEntityProviderFactory implements JpaEntityProviderFactory {
    @Override public JpaEntityProvider create(KeycloakSession session) {
        return new JpaEntityProvider() {
            @Override public List<Class<?>> getEntities() { return List.of(EnrollmentRecord.class); }
            @Override public String getChangelogLocation() { return "META-INF/nephos-enrollment.xml"; }
            @Override public String getFactoryId() { return getId(); }
            @Override public void close() {}
        };
    }
    @Override public String getId() { return "nephos-enrollment"; }
    @Override public void init(Config.Scope config) {}
    @Override public void postInit(KeycloakSessionFactory factory) {
        try (var session = factory.create()) {
            session.getProvider(org.keycloak.timer.TimerProvider.class).scheduleTask(taskSession -> {
                EnrollmentStore store = new EnrollmentStore(taskSession);
                store.lock();
                store.cleanup(java.time.Instant.now().getEpochSecond());
            }, 60000, "nephos-enrollment-expiry");
        }
    }
    @Override public void close() {}
}
