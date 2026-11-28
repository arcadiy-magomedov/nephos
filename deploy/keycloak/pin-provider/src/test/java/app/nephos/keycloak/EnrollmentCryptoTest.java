package app.nephos.keycloak;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.security.KeyPairGenerator;
import java.security.Signature;
import java.security.interfaces.ECPublicKey;
import java.security.spec.ECGenParameterSpec;
import java.util.Arrays;
import java.util.Locale;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

final class EnrollmentCryptoTest {
    @Test void secretHasFullEntropySizeAndVerifierIsOneWay() {
        String first = EnrollmentCrypto.random(), second = EnrollmentCrypto.random();
        assertEquals(32, EnrollmentCrypto.decode(first).length);
        assertNotEquals(first, second);
        assertNotEquals(first, EnrollmentCrypto.digest(first));
        assertEquals(EnrollmentCrypto.digest(first), EnrollmentCrypto.digest(first));
        assertThrows(IllegalArgumentException.class, () -> EnrollmentCrypto.decode(first + "="));
    }
    @Test void proofIsP256KeyAndChallengeBound() throws Exception {
        var generator = KeyPairGenerator.getInstance("EC");
        generator.initialize(new ECGenParameterSpec("secp256r1"));
        var pair = generator.generateKeyPair();
        ECPublicKey publicKey = (ECPublicKey) pair.getPublic();
        byte[] point = new byte[65]; point[0] = 4;
        byte[] x = publicKey.getW().getAffineX().toByteArray(), y = publicKey.getW().getAffineY().toByteArray();
        System.arraycopy(x, Math.max(0, x.length - 32), point, 33 - Math.min(x.length, 32), Math.min(x.length, 32));
        System.arraycopy(y, Math.max(0, y.length - 32), point, 65 - Math.min(y.length, 32), Math.min(y.length, 32));
        String key = EnrollmentCrypto.encode(point);
        assertEquals(org.keycloak.util.JWKSUtils.computeThumbprint(
                org.keycloak.jose.jwk.JWKBuilder.create().ec(publicKey)), EnrollmentCrypto.jwkThumbprint(key));
        String challenge = "nephos-qr-v1\nhttps://photos.example.test\nnephos-ios\ninvite\nrequest\n"
                + EnrollmentCrypto.fingerprint(key) + "\nchallenge\n" + EnrollmentCrypto.random();
        var signer = Signature.getInstance("SHA256withECDSA");
        signer.initSign(pair.getPrivate()); signer.update(challenge.getBytes(StandardCharsets.UTF_8));
        String signature = EnrollmentCrypto.encode(signer.sign());
        assertTrue(EnrollmentCrypto.verify(key, challenge, signature));
        assertFalse(EnrollmentCrypto.verify(key, challenge.replace("request", "another-request"), signature));
        assertFalse(EnrollmentCrypto.verify(key, challenge.replace("example.test", "attacker.test"), signature));
        point[0] = 3;
        assertFalse(EnrollmentCrypto.verify(EnrollmentCrypto.encode(point), challenge, signature));
        point[0] = 4;
        assertFalse(EnrollmentCrypto.verify(EnrollmentCrypto.encode(Arrays.copyOf(point, 64)), challenge, signature));
        point[64] ^= 1;
        assertFalse(EnrollmentCrypto.verify(EnrollmentCrypto.encode(point), challenge, signature));
        assertThrows(IllegalArgumentException.class,
                () -> EnrollmentCrypto.fingerprint(EnrollmentCrypto.encode(Arrays.copyOf(point, 64))));
    }
    @Test void canonicalRequestIdentityRejectsAliases() {
        assertEquals("ac5ca275-6e22-4f0a-ab70-c915f93fb516",
                EnrollmentResource.uuid("ac5ca275-6e22-4f0a-ab70-c915f93fb516"));
        assertThrows(IllegalArgumentException.class,
                () -> EnrollmentResource.uuid("AC5CA275-6E22-4F0A-AB70-C915F93FB516"));
        assertThrows(IllegalArgumentException.class, () -> EnrollmentResource.uuid("1-1-1-1-1"));
    }
    @Test void enrollmentInputRequiresBoundedJsonObject() {
        for (String invalid : new String[]{"null", "[]", "42", "{", " ".repeat(4097)}) {
            assertThrows(IllegalArgumentException.class, () -> EnrollmentResource.input(
                    new ByteArrayInputStream(invalid.getBytes(StandardCharsets.UTF_8))));
        }
        assertEquals("nephos-ios", EnrollmentResource.input(new ByteArrayInputStream(
                "{\"clientId\":\"nephos-ios\"}".getBytes(StandardCharsets.UTF_8))).get("clientId"));
    }
    @Test void loginPinRemainsAsciiInLocalizedRuntime() {
        Locale previous = Locale.getDefault();
        try {
            Locale.setDefault(Locale.forLanguageTag("ar"));
            assertTrue(PinSupport.newPin().matches("[0-9]{8}"));
        } finally {
            Locale.setDefault(previous);
        }
    }
    @Test void onlyActiveUnexpiredInvitationsCanBeCancelled() {
        assertTrue(EnrollmentResource.isCancellable("active", 200, 100));
        assertFalse(EnrollmentResource.isCancellable("active", 100, 100));
        assertFalse(EnrollmentResource.isCancellable("used", 200, 100));
        assertFalse(EnrollmentResource.isCancellable("revoked", 200, 100));
        assertFalse(EnrollmentResource.isCancellable("expired", 200, 100));
    }
}
