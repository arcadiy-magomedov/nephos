package app.nephos.keycloak;

import java.math.BigInteger;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.AlgorithmParameters;
import java.security.KeyFactory;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.security.Signature;
import java.security.spec.ECGenParameterSpec;
import java.security.spec.ECParameterSpec;
import java.security.spec.ECPoint;
import java.security.spec.ECPublicKeySpec;
import java.util.Arrays;
import java.util.Base64;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

final class EnrollmentCrypto {
    private static final SecureRandom RANDOM = new SecureRandom();
    static String keyVersion() {
        String version = System.getenv().getOrDefault("NEPHOS_QR_KEY_VERSION", "1");
        if (!version.matches("[a-zA-Z0-9_-]{1,32}")) throw new IllegalStateException("Invalid key version");
        String key = System.getenv("NEPHOS_QR_DELIVERY_KEY");
        if (key == null || Base64.getDecoder().decode(key).length != 32)
            throw new IllegalStateException("Missing delivery key");
        return version + ":" + digest(key);
    }
    static String origin() {
        String value = System.getenv("NEPHOS_PUBLIC_ORIGIN");
        if (value == null) throw new IllegalStateException("Missing canonical public origin");
        URI uri = URI.create(value);
        if (!"https".equals(uri.getScheme()) || uri.getHost() == null || uri.getUserInfo() != null
                || uri.getQuery() != null || uri.getFragment() != null
                || (uri.getPath() != null && !uri.getPath().isEmpty())
                || !value.equals(uri.toASCIIString())) throw new IllegalStateException("Invalid public origin");
        return value;
    }
    static String encode(byte[] bytes) { return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes); }
    static byte[] decode(String value) {
        if (value == null || value.length() > 32768) throw new IllegalArgumentException();
        byte[] bytes = Base64.getUrlDecoder().decode(value);
        if (!encode(bytes).equals(value)) throw new IllegalArgumentException();
        return bytes;
    }
    static String random() { byte[] bytes = new byte[32]; RANDOM.nextBytes(bytes); return encode(bytes); }
    static String digest(String value) {
        try { return encode(MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8))); }
        catch (java.security.GeneralSecurityException exception) { throw new IllegalStateException(exception); }
    }
    static String fingerprint(String key) {
        try {
            byte[] bytes = decode(key);
            if (bytes.length != 65 || bytes[0] != 4) throw new IllegalArgumentException();
            publicKey(bytes);
            return encode(MessageDigest.getInstance("SHA-256").digest(bytes));
        } catch (java.security.GeneralSecurityException exception) { throw new IllegalArgumentException(exception); }
    }
    static String jwkThumbprint(String key) {
        fingerprint(key);
        byte[] point = decode(key);
        return digest("{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\""
                + encode(Arrays.copyOfRange(point, 1, 33)) + "\",\"y\":\""
                + encode(Arrays.copyOfRange(point, 33, 65)) + "\"}");
    }
    private static java.security.PublicKey publicKey(byte[] bytes) throws java.security.GeneralSecurityException {
        AlgorithmParameters parameters = AlgorithmParameters.getInstance("EC");
        parameters.init(new ECGenParameterSpec("secp256r1"));
        return KeyFactory.getInstance("EC").generatePublic(new ECPublicKeySpec(new ECPoint(
                new BigInteger(1, Arrays.copyOfRange(bytes, 1, 33)),
                new BigInteger(1, Arrays.copyOfRange(bytes, 33, 65))),
                parameters.getParameterSpec(ECParameterSpec.class)));
    }
    static boolean verify(String key, String challenge, String signature) {
        try {
            Signature verifier = Signature.getInstance("SHA256withECDSA");
            verifier.initVerify(publicKey(decode(key)));
            verifier.update(challenge.getBytes(StandardCharsets.UTF_8));
            return verifier.verify(decode(signature));
        } catch (java.security.GeneralSecurityException | IllegalArgumentException exception) { return false; }
    }
    static String crypt(String value, String metadata, boolean encrypt) {
        try {
            byte[] key = Base64.getDecoder().decode(System.getenv("NEPHOS_QR_DELIVERY_KEY"));
            if (key.length != 32) throw new IllegalStateException("Invalid delivery key");
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            byte[] nonce;
            byte[] bytes;
            if (encrypt) {
                nonce = new byte[12]; RANDOM.nextBytes(nonce);
                bytes = value.getBytes(StandardCharsets.UTF_8);
            } else {
                byte[] envelope = decode(value);
                nonce = Arrays.copyOfRange(envelope, 0, 12);
                bytes = Arrays.copyOfRange(envelope, 12, envelope.length);
            }
            cipher.init(encrypt ? Cipher.ENCRYPT_MODE : Cipher.DECRYPT_MODE,
                    new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, nonce));
            cipher.updateAAD(("nephos-qr-receipt-v1\n" + keyVersion() + "\n" + metadata).getBytes(StandardCharsets.UTF_8));
            byte[] result = cipher.doFinal(bytes);
            if (!encrypt) return new String(result, StandardCharsets.UTF_8);
            byte[] envelope = Arrays.copyOf(nonce, nonce.length + result.length);
            System.arraycopy(result, 0, envelope, nonce.length, result.length);
            return encode(envelope);
        } catch (Exception exception) { throw new IllegalStateException("Delivery encryption unavailable", exception); }
    }
}
