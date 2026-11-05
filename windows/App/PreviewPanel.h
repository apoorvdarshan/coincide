#pragma once
#include "PreviewPolicy.h"
#include "NativeStrings.h"
#include <windows.h>
#undef GetCurrentTime
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Microsoft.Web.WebView2.Core.h>
#include <winrt/Windows.Foundation.h>
#include <filesystem>
#include <memory>
#include <functional>

namespace coincide {
namespace preview_xaml = winrt::Microsoft::UI::Xaml;
namespace preview_controls = winrt::Microsoft::UI::Xaml::Controls;
namespace preview_core = winrt::Microsoft::Web::WebView2::Core;

// Generated output has no relationship to a user's browsing profile, cookies or saved logins.
// Construct only for an explicit Preview action. All methods run on the owning UI thread.
class PreviewPanel : public std::enable_shared_from_this<PreviewPanel> {
public:
    static std::shared_ptr<PreviewPanel> create(std::filesystem::path preview_root, bool fixture_mode = false) {
        auto result = std::shared_ptr<PreviewPanel>(new PreviewPanel(std::move(preview_root), fixture_mode));
        result->build(); return result;
    }
    preview_controls::Grid view() const {return root_;}
    bool ready() const {return ready_;}
    const std::string& error() const {return error_;}
    std::size_t blocked_requests() const {return blocked_requests_;}
    void set_changed_callback(std::function<void()> callback) {changed_ = std::move(callback);}
    void set_visible(bool value) {root_.Visibility(value ? preview_xaml::Visibility::Visible : preview_xaml::Visibility::Collapsed);}
    void load_inline(std::string html, bool svg = false) {
        content_ = preview_document(html, svg); error_.clear();
        if (ready_) render();
        else if (page_.IsLoaded()) initialize();
    }
    void close() noexcept {
        if (closed_) return; closed_ = true; ready_ = false;
        try {page_.Close();} catch (...) { }
    }
    // Test harness only: this does not install a page-to-app bridge or expose any host object.
    winrt::Windows::Foundation::IAsyncOperation<winrt::hstring> fixture_evaluate(std::wstring script) {
        auto lifetime = shared_from_this();
        if (!fixture_mode_ || !ready_) throw std::logic_error("Preview inspection is restricted to offline fixtures");
        co_return co_await page_.CoreWebView2().ExecuteScriptAsync(script);
    }
private:
    std::filesystem::path profile_directory_;
    bool fixture_mode_{}, initializing_{}, ready_{}, closed_{}, pending_navigation_{};
    std::string content_, error_;
    std::size_t blocked_requests_{};
    preview_controls::Grid root_{nullptr};
    preview_controls::WebView2 page_{nullptr};
    preview_controls::TextBlock status_{nullptr};
    preview_core::CoreWebView2Environment environment_{nullptr};
    std::function<void()> changed_;

    PreviewPanel(std::filesystem::path root, bool fixture) : fixture_mode_(fixture) {
        if (!root.is_absolute()) throw std::invalid_argument("Preview needs an absolute isolated data directory");
        winrt::guid identity; winrt::check_hresult(CoCreateGuid(reinterpret_cast<GUID*>(&identity)));
        profile_directory_ = std::move(root) / winrt::to_hstring(identity).c_str();
        std::filesystem::create_directories(profile_directory_);
    }
    void build() {
        root_ = preview_controls::Grid{};
        preview_xaml::Automation::AutomationProperties::SetAutomationId(root_, L"PreviewPanel");
        page_ = preview_controls::WebView2{};
        preview_xaml::Automation::AutomationProperties::SetAutomationId(page_, L"PreviewPage");
        root_.Children().Append(page_);
        status_ = preview_controls::TextBlock{}; status_.Text(ui_text(L"Preparing preview…")); status_.TextWrapping(preview_xaml::TextWrapping::Wrap);
        status_.VerticalAlignment(preview_xaml::VerticalAlignment::Top); root_.Children().Append(status_);
        page_.Loaded([weak = weak_from_this()](const auto&, const auto&) {if (const auto self = weak.lock()) self->initialize();});
    }
    void notify() {if (changed_) try {changed_();} catch (...) { }}
    void fail(std::string error) noexcept {
        error_ = std::move(error); ready_ = false; initializing_ = false;
        try {status_.Text(winrt::to_hstring(error_)); page_.Close();} catch (...) { }
        notify();
    }
    void render() {
        if (closed_ || content_.empty()) return;
        pending_navigation_ = true; page_.NavigateToString(winrt::to_hstring(content_));
    }
    winrt::fire_and_forget initialize() {
        auto lifetime = shared_from_this();
        if (closed_ || ready_ || initializing_) co_return;
        initializing_ = true;
        try {
            preview_core::CoreWebView2EnvironmentOptions options;
            options.AllowSingleSignOnUsingOSPrimaryAccount(false);
            options.AdditionalBrowserArguments(L"--disable-background-networking --disable-component-update --disable-sync --no-first-run --force-webrtc-ip-handling-policy=disable_non_proxied_udp");
            environment_ = co_await preview_core::CoreWebView2Environment::CreateWithOptionsAsync(L"", profile_directory_.wstring(), options);
            if (closed_) co_return;
            auto controller = environment_.CreateCoreWebView2ControllerOptions(); controller.ProfileName(L"Preview"); controller.IsInPrivateModeEnabled(true);
            co_await page_.EnsureCoreWebView2Async(environment_, controller);
            if (closed_) co_return;
            const auto core = page_.CoreWebView2();
            if (!core.Profile().IsInPrivateModeEnabled()) throw std::runtime_error("The preview did not create an isolated private profile");
            const auto settings = core.Settings();
            settings.IsWebMessageEnabled(false); settings.AreHostObjectsAllowed(false);
            settings.IsPasswordAutosaveEnabled(false); settings.IsGeneralAutofillEnabled(false);
            settings.AreDefaultScriptDialogsEnabled(false); settings.AreDefaultContextMenusEnabled(false);
            settings.AreDevToolsEnabled(false); settings.AreBrowserAcceleratorKeysEnabled(false); settings.IsStatusBarEnabled(false);
            wire(core);
            // Both commands must succeed before generated code is admitted. The host never responds
            // to an intercepted file chooser, so generated content cannot open a native picker.
            co_await core.CallDevToolsProtocolMethodAsync(L"Page.setInterceptFileChooserDialog", L"{\"enabled\":true}");
            co_await core.CallDevToolsProtocolMethodAsync(L"Network.enable", L"{}");
            co_await core.CallDevToolsProtocolMethodAsync(L"Network.setBlockedURLs", L"{\"urls\":[\"http://*\",\"https://*\",\"ws://*\",\"wss://*\",\"file://*\",\"ftp://*\"]}");
            // CSP governs fetch/images/styles/frames. WebRTC can use other transports, so remove
            // its constructors in every document before any generated script is evaluated.
            co_await core.AddScriptToExecuteOnDocumentCreatedAsync(LR"JS((()=>{for(const key of ['RTCPeerConnection','webkitRTCPeerConnection','RTCIceTransport','RTCDataChannel','WebTransport','Worker','SharedWorker']){try{Object.defineProperty(globalThis,key,{value:undefined,writable:false,configurable:false});}catch{}}})();)JS");
            if (closed_) co_return;
            ready_ = true; initializing_ = false; status_.Text(L""); render(); notify();
        } catch (const winrt::hresult_error& error) {fail(winrt::to_string(error.message()));}
          catch (const std::exception& error) {fail(error.what());}
    }
    void wire(const preview_core::CoreWebView2& core) {
        const auto weak = weak_from_this();
        core.NavigationStarting([weak](const auto&, const preview_core::CoreWebView2NavigationStartingEventArgs& args) {
            if (const auto self = weak.lock()) {
                const auto uri = winrt::to_string(args.Uri());
                const bool allow = self->pending_navigation_ && preview_inline_navigation(uri, true);
                self->pending_navigation_ = false;
                if (!allow) {args.Cancel(true); ++self->blocked_requests_;}
            } else args.Cancel(true);
        });
        core.FrameNavigationStarting([weak](const auto&, const preview_core::CoreWebView2NavigationStartingEventArgs& args) {
            if (!preview_inline_navigation(winrt::to_string(args.Uri()), false)) {args.Cancel(true); if (const auto self = weak.lock()) ++self->blocked_requests_;}
        });
        core.AddWebResourceRequestedFilter(L"*", preview_core::CoreWebView2WebResourceContext::All);
        core.WebResourceRequested([weak](const auto&, const preview_core::CoreWebView2WebResourceRequestedEventArgs& args) {
            if (const auto self = weak.lock()) {
                ++self->blocked_requests_;
                // A synthetic local response is final: no request is forwarded to a host/network.
                args.Response(self->environment_.CreateWebResourceResponse(nullptr, 403, L"Preview resource blocked", L"Content-Length: 0\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\n"));
            }
        });
        core.PermissionRequested([](const auto&, const preview_core::CoreWebView2PermissionRequestedEventArgs& args) {args.State(preview_core::CoreWebView2PermissionState::Deny); args.Handled(true); args.SavesInProfile(false);});
        core.NewWindowRequested([](const auto&, const preview_core::CoreWebView2NewWindowRequestedEventArgs& args) {args.Handled(true);});
        core.DownloadStarting([](const auto&, const preview_core::CoreWebView2DownloadStartingEventArgs& args) {args.Cancel(true); args.Handled(true);});
        core.BasicAuthenticationRequested([](const auto&, const preview_core::CoreWebView2BasicAuthenticationRequestedEventArgs& args) {args.Cancel(true);});
        core.ServerCertificateErrorDetected([](const auto&, const preview_core::CoreWebView2ServerCertificateErrorDetectedEventArgs& args) {args.Action(preview_core::CoreWebView2ServerCertificateErrorAction::Cancel);});
        core.LaunchingExternalUriScheme([](const auto&, const preview_core::CoreWebView2LaunchingExternalUriSchemeEventArgs& args) {args.Cancel(true);});
        core.ScriptDialogOpening([](const auto&, const auto&) { });
        core.ProcessFailed([weak](const auto&, const auto&) {if (const auto self = weak.lock()) self->fail(winrt::to_string(ui_text(L"The preview process stopped.")));});
    }
};
} // namespace coincide
