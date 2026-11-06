/** CI-only checks: native handled errors survive; unhandled errors remain fatal. */
public class HotspotExceptionProbe {
    private static native int handled();
    private static native void unhandled();
    private static native void accessViolation();

    public static void main(String[] args) {
        System.load(args[0]);
        switch (args[1]) {
            case "handled" -> {
                if (handled() != 0x80090016) {
                    throw new AssertionError("Native handler did not receive NTE_BAD_KEYSET");
                }
                System.out.println("Handled cryptography exception survived JNI");
            }
            case "unhandled" -> unhandled();
            case "access-violation" -> accessViolation();
            default -> throw new IllegalArgumentException(args[1]);
        }
    }
}
