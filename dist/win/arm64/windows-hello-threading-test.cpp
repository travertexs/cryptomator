#include "src/main/native/org_cryptomator_windows_keychain_WindowsHello_Native.cpp"
#include <winrt/Windows.System.Threading.h>

static void require(bool condition, const char* message) {
    if (!condition) { throw std::runtime_error(message); }
}

static void checkWorker() {
    const auto callerId = GetCurrentThreadId();
    const auto result = runOnHelloThread([callerId] {
        require(GetCurrentThreadId() != callerId, "Hello executed on the caller thread");
        APTTYPE type;
        APTTYPEQUALIFIER qualifier;
        winrt::check_hresult(CoGetApartmentType(&type, &qualifier));
        require(type == APTTYPE_MTA, "Hello worker is not MTA");
        // A pending operation (not an already-completed availability probe) is
        // essential: C++/WinRT asserts when .get() blocks an STA thread.
        Windows::System::Threading::ThreadPool::RunAsync([](auto const&) {
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }).get();
        return 42;
    });
    require(result == 42, "Worker lost its result");
    bool caught = false;
    try {
        runOnHelloThread([]() -> bool { throw winrt::hresult_error(E_ACCESSDENIED); });
    } catch (const winrt::hresult_error& error) {
        caught = error.code() == E_ACCESSDENIED;
    }
    require(caught, "Worker did not propagate an API failure");
}

int main() {
    try {
        // Match a JavaFX/STA caller, then an uninitialized background caller.
        winrt::init_apartment(winrt::apartment_type::single_threaded);
        for (int i = 0; i < 8; ++i) { checkWorker(); }
        APTTYPE type;
        APTTYPEQUALIFIER qualifier;
        winrt::check_hresult(CoGetApartmentType(&type, &qualifier));
        require(type == APTTYPE_STA || type == APTTYPE_MAINSTA, "Caller apartment changed");
        winrt::uninit_apartment();
        checkWorker();

        // Exercise the actual KeyCredentialManager probe, without the old
        // consent-device preflight hiding it on an unconfigured CI account.
        const auto supported = Java_org_cryptomator_windows_keychain_WindowsHello_00024Native_isSupported(nullptr, nullptr);
        std::cout << "Windows Hello supported on runner: " << (supported == JNI_TRUE) << '\n';
        std::cout << "Windows Hello threading regression checks passed\n";
        return 0;
    } catch (const winrt::hresult_error& error) {
        std::cerr << winrt::to_string(error.message()) << '\n';
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
    }
    return 1;
}
