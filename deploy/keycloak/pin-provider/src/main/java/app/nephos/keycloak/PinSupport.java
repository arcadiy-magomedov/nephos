package app.nephos.keycloak;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import javax.crypto.Mac;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import java.util.Base64;
import java.util.HexFormat;
import java.util.Locale;

final class PinSupport {
    static final String GRANT_TYPE = "urn:nephos:params:oauth:grant-type:login-pin";
    static final String DEVICE_ID_NOTE = "nephos.device_id";
    static final String DEVICE_NAME_NOTE = "nephos.device_name";
    static final int PIN_TTL_SECONDS = 30 * 60;
    private static final SecureRandom RANDOM = new SecureRandom();

    private PinSupport() {}

    static String newPin() {
        return "%08d".formatted(RANDOM.nextInt(100_000_000));
    }

    static String pinKey(String realm, String userId) {
        return "nephos:login-pin:" + digest(realm + "\u0000" + userId);
    }

    static String lockKey(String realm, String userId) {
        return "nephos:login-pin-lock:" + digest(realm + "\u0000" + userId);
    }

    static String attemptsKey(String realm, String userId) {
        return "nephos:login-pin-attempts:" + digest(realm + "\u0000" + userId);
    }

    static String requestKey(String kind, String value) {
        return "nephos:pin-request:" + kind + ":" + digest(value);
    }

    static String normalizeEmail(String value) {
        if (value == null) return null;
        String email = value.trim().toLowerCase(Locale.ROOT);
        if (email.length() > 320) return null;
        String[] parts = email.split("@", -1);
        if (parts.length != 2 || parts[0].isEmpty() || parts[0].length() > 64
                || !parts[0].matches("[a-z0-9!#$%&'*+/=?^_`{|}~.\\-]+")
                || parts[0].startsWith(".") || parts[0].endsWith(".") || parts[0].contains("..")) return null;
        String[] labels = parts[1].split("\\.", -1);
        if (labels.length < 2) return null;
        for (String label : labels) {
            if (label.isEmpty() || label.length() > 63
                    || !label.matches("[a-z0-9](?:[a-z0-9-]*[a-z0-9])?")) return null;
        }
        return email;
    }

    static String encryptPin(String pin, String key) {
        byte[] iv = new byte[12];
        RANDOM.nextBytes(iv);
        try {
            Cipher cipher = pinCipher(Cipher.ENCRYPT_MODE, iv, key);
            byte[] encrypted = cipher.doFinal(pin.getBytes(StandardCharsets.US_ASCII));
            byte[] result = new byte[iv.length + encrypted.length];
            System.arraycopy(iv, 0, result, 0, iv.length);
            System.arraycopy(encrypted, 0, result, iv.length, encrypted.length);
            return Base64.getEncoder().encodeToString(result);
        } catch (Exception exception) {
            throw new IllegalStateException("PIN encryption unavailable", exception);
        }
    }

    static String decryptPin(String encrypted, String key) {
        try {
            byte[] value = Base64.getDecoder().decode(encrypted);
            if (value.length != 36) throw new IllegalArgumentException("Invalid PIN ciphertext");
            byte[] iv = java.util.Arrays.copyOf(value, 12);
            return new String(pinCipher(Cipher.DECRYPT_MODE, iv, key)
                    .doFinal(value, 12, value.length - 12), StandardCharsets.US_ASCII);
        } catch (Exception exception) {
            throw new IllegalStateException("PIN decryption unavailable", exception);
        }
    }

    private static Cipher pinCipher(int mode, byte[] iv, String key) throws Exception {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(pepper(), "HmacSHA256"));
        byte[] derived = mac.doFinal("nephos:requested-pin:aes-gcm:v1".getBytes(StandardCharsets.US_ASCII));
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(mode, new SecretKeySpec(derived, "AES"), new GCMParameterSpec(128, iv));
        cipher.updateAAD(key.getBytes(StandardCharsets.UTF_8));
        return cipher;
    }

    private static byte[] pepper() {
        String pepper = System.getenv("NEPHOS_PIN_PEPPER");
        if (pepper == null || pepper.length() < 32) {
            throw new IllegalStateException("NEPHOS_PIN_PEPPER must contain at least 32 characters");
        }
        return pepper.getBytes(StandardCharsets.UTF_8);
    }

    static String pinDigest(String pin) {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(pepper(), "HmacSHA256"));
            return HexFormat.of().formatHex(mac.doFinal(pin.getBytes(StandardCharsets.US_ASCII)));
        } catch (Exception exception) {
            throw new IllegalStateException("HMAC-SHA-256 is unavailable", exception);
        }
    }

    static boolean constantTimeEquals(String first, String second) {
        return MessageDigest.isEqual(first.getBytes(StandardCharsets.US_ASCII),
                second.getBytes(StandardCharsets.US_ASCII));
    }

    private static String digest(String value) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(value.getBytes(StandardCharsets.UTF_8)));
        } catch (Exception exception) {
            throw new IllegalStateException("SHA-256 is unavailable", exception);
        }
    }
}
