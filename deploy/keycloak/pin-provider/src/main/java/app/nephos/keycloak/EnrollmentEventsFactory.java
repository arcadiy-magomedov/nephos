package app.nephos.keycloak;

import org.keycloak.Config;
import org.keycloak.events.Event;
import org.keycloak.events.EventListenerProvider;
import org.keycloak.events.EventListenerProviderFactory;
import org.keycloak.events.EventType;
import org.keycloak.events.admin.AdminEvent;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;

public final class EnrollmentEventsFactory implements EventListenerProviderFactory {
    @Override public EventListenerProvider create(KeycloakSession session) {
        return new EventListenerProvider() {
            @Override public void onEvent(Event event) {
                if (event.getSessionId() == null || !"nephos".equals(session.getContext().getRealm().getName())) return;
                if (event.getType() == EventType.REFRESH_TOKEN || event.getType() == EventType.LOGOUT) {
                    EnrollmentStore store = new EnrollmentStore(session);
                    store.lock();
                    store.invalidateSession(event.getSessionId());
                }
            }
            @Override public void onEvent(AdminEvent event, boolean includeRepresentation) {
                if (session.getContext().getRealm() == null
                        || !"nephos".equals(session.getContext().getRealm().getName())
                        || event.getOperationType() != org.keycloak.events.admin.OperationType.UPDATE
                        || event.getResourcePath() == null || !event.getResourcePath().matches("users/[a-f0-9-]{36}")) return;
                String subject = event.getResourcePath().substring(6);
                EnrollmentStore store = new EnrollmentStore(session);
                store.lock(); store.fence(subject, true);
                var user = session.users().getUserById(session.getContext().getRealm(), subject);
                if (user != null) {
                    session.singleUseObjects().remove(PinSupport.pinKey("nephos", subject));
                    session.sessions().removeUserSessions(session.getContext().getRealm(), user);
                    try (var offline = session.sessions().getOfflineUserSessionsStream(session.getContext().getRealm(), user)) {
                        offline.toList().forEach(item -> session.sessions().removeOfflineUserSession(
                                session.getContext().getRealm(), item));
                    }
                    QrGrant.prepare(session);
                }
            }
            @Override public void close() {}
        };
    }
    @Override public String getId() { return "nephos-enrollment"; }
    @Override public void init(Config.Scope config) {}
    @Override public void postInit(KeycloakSessionFactory factory) {}
    @Override public void close() {}
}
