package org.cryptomator.windows.keychain;

import java.nio.charset.StandardCharsets;

/** Standalone JNI regression probe; never creates a Hello credential or reads a vault. */
public class WindowsHello {
    private static class Native {
        native boolean isSupported();
        native byte[] encrypt(byte[] keyId, byte[] cleartext, byte[] salt);
        native byte[] decrypt(byte[] keyId, byte[] ciphertext, byte[] salt);
    }

    public static void main(String[] args) {
        System.load(args[0]);
        var api = new Native();
        for (int i = 0; i < 8; i++) {
            System.out.println("Hello available: " + api.isSupported());
        }
        // Invalid input must be rejected before any key creation or prompt.
        if (api.encrypt(new byte[0], new byte[16], new byte[16]) != null) {
            throw new AssertionError("Empty key identifier was accepted");
        }
        var keyId = "org.cryptomator.ci-never-created\0".getBytes(StandardCharsets.UTF_16LE);
        if (api.decrypt(keyId, new byte[1], new byte[16]) != null) {
            throw new AssertionError("Truncated ciphertext was accepted");
        }
        System.out.println("Windows Hello JNI regression checks passed");
    }
}
