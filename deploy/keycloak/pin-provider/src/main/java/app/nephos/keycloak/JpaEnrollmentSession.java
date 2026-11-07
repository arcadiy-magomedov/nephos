package app.nephos.keycloak;

import java.util.HashMap;
import java.util.Map;
import org.keycloak.models.*;
import org.keycloak.models.session.*;

final class JpaEnrollmentSession {
    final PersistentUserSessionAdapter online;
    final PersistentAuthenticatedClientSessionAdapter onlineClient;
    private final PersistentAuthenticatedClientSessionAdapter offlineClient;
    private final KeycloakSession session;
    private final UserSessionPersisterProvider persister;

    JpaEnrollmentSession(KeycloakSession session, UserModel user, ClientModel client, String id,
                         String deviceName, long epoch) {
        this.session = session;
        persister = session.getProvider(UserSessionPersisterProvider.class);
        RealmModel realm = session.getContext().getRealm();
        int now = org.keycloak.common.util.Time.currentTime();
        online = userSession(realm, user, id, now, false, deviceName, epoch);
        var offline = userSession(realm, user, id, now, true, deviceName, epoch);
        onlineClient = clientSession(realm, client, online, now);
        offlineClient = clientSession(realm, client, offline, now);
        // Use Keycloak's own persistent adapters/serializer and JPA persister. No cache-only
        // ADD_IF_ABSENT sessions or separate after-completion transaction can escape the claim.
        persister.createUserSession(online, false);
        persister.createUserSession(offline, true);
        persister.createClientSession(onlineClient, false);
        persister.createClientSession(offlineClient, true);
    }
    private PersistentUserSessionAdapter userSession(RealmModel realm, UserModel user, String id, int now,
                                                     boolean offline, String deviceName, long epoch) {
        UserRow row = new UserRow();
        row.id = id; row.started = now; row.refresh = now; row.offline = offline;
        var adapter = new PersistentUserSessionAdapter(session, row, realm, user.getId(), new HashMap<>());
        adapter.setUser(user); adapter.setRealm(realm); adapter.setLoginUsername(user.getUsername());
        adapter.setIpAddress(session.getContext().getConnection().getRemoteAddr());
        adapter.setAuthMethod("nephos_qr"); adapter.setState(UserSessionModel.State.LOGGED_IN);
        adapter.setNote(PinSupport.DEVICE_ID_NOTE, id);
        adapter.setNote(PinSupport.DEVICE_NAME_NOTE, deviceName);
        adapter.setNote("nephos.qr.epoch", Long.toString(epoch));
        return adapter;
    }
    private PersistentAuthenticatedClientSessionAdapter clientSession(RealmModel realm, ClientModel client,
                                                                       PersistentUserSessionAdapter user, int now) {
        ClientRow row = new ClientRow();
        row.id = user.getId(); row.clientId = client.getId(); row.timestamp = now;
        var adapter = new PersistentAuthenticatedClientSessionAdapter(session, row, realm, client, user);
        adapter.setProtocol(org.keycloak.protocol.oidc.OIDCLoginProtocol.LOGIN_PROTOCOL);
        adapter.setAction(AuthenticatedClientSessionModel.Action.AUTHENTICATE.name());
        adapter.setTimestamp(now);
        adapter.setNote(AuthenticatedClientSessionModel.STARTED_AT_NOTE, Integer.toString(now));
        adapter.setNote(AuthenticatedClientSessionModel.USER_SESSION_STARTED_AT_NOTE, Integer.toString(now));
        user.getAuthenticatedClientSessions().put(client.getId(), adapter);
        return adapter;
    }
    void persistClientChanges() { persister.createClientSession(onlineClient, false); }
    void synchronizeOfflineContext() {
        onlineClient.getNotes().forEach(offlineClient::setNote);
        offlineClient.setRedirectUri(onlineClient.getRedirectUri());
        offlineClient.setProtocol(onlineClient.getProtocol());
        offlineClient.setAction(onlineClient.getAction());
        persister.createClientSession(onlineClient, false);
        persister.createClientSession(offlineClient, true);
    }
    private static final class UserRow implements PersistentUserSessionModel {
        String id, data = "{}"; int started, refresh, coarse; boolean offline, rememberMe;
        @Override public String getUserSessionId() { return id; }
        @Override public void setUserSessionId(String value) { id = value; }
        @Override public int getStarted() { return started; }
        @Override public void setStarted(int value) { started = value; }
        @Override public int getLastSessionRefresh() { return refresh; }
        @Override public void setLastSessionRefresh(int value) { refresh = value; }
        @Override public int getLastSessionRefreshCoarse() { return coarse; }
        @Override public void setLastSessionRefreshCoarse(int value) { coarse = value; }
        @Override public boolean isOffline() { return offline; }
        @Override public void setOffline(boolean value) { offline = value; }
        @Override public String getData() { return data; }
        @Override public void setData(String value) { data = value; }
        @Override public void setRealmId(String value) {}
        @Override public void setUserId(String value) {}
        @Override public void setBrokerSessionId(String value) {}
        @Override public boolean isRememberMe() { return rememberMe; }
        @Override public void setRememberMe(boolean value) { rememberMe = value; }
    }
    private static final class ClientRow implements PersistentClientSessionModel {
        String id, clientId, data = "{}"; int timestamp;
        @Override public String getUserSessionId() { return id; }
        @Override public void setUserSessionId(String value) { id = value; }
        @Override public String getClientId() { return clientId; }
        @Override public void setClientId(String value) { clientId = value; }
        @Override public int getTimestamp() { return timestamp; }
        @Override public void setTimestamp(int value) { timestamp = value; }
        @Override public String getData() { return data; }
        @Override public void setData(String value) { data = value; }
    }
}
