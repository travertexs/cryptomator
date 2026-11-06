#include <windows.h>
#include <jni.h>

extern "C" JNIEXPORT jint JNICALL Java_HotspotExceptionProbe_handled(JNIEnv*, jclass) {
    __try {
        RaiseException(static_cast<DWORD>(NTE_BAD_KEYSET), 0, 0, nullptr);
    } __except (GetExceptionCode() == static_cast<DWORD>(NTE_BAD_KEYSET)
                ? EXCEPTION_EXECUTE_HANDLER : EXCEPTION_CONTINUE_SEARCH) {
        return static_cast<jint>(NTE_BAD_KEYSET);
    }
    return 0;
}

extern "C" JNIEXPORT void JNICALL Java_HotspotExceptionProbe_unhandled(JNIEnv*, jclass) {
    RaiseException(static_cast<DWORD>(NTE_BAD_KEYSET), 0, 0, nullptr);
}

extern "C" JNIEXPORT void JNICALL Java_HotspotExceptionProbe_accessViolation(JNIEnv*, jclass) {
    RaiseException(EXCEPTION_ACCESS_VIOLATION, 0, 0, nullptr);
}
