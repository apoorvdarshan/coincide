#pragma once
#include "NativeStrings.h"
#include "../Runtime/UsageStore.h"
#include "../Runtime/ProviderAccounts.h"
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <iomanip>
#include <sstream>

namespace coincide {
struct UsageLabel {std::string id,label;};
struct UsageAccountStatus {
    std::string provider,profile_id,label,version,account_scope,source;
    bool verified{};
    static UsageAccountStatus from(const ProviderAccountMetadata& metadata){return {metadata.provider,metadata.profile_id,metadata.label,metadata.version,metadata.scope,metadata.identity_source,metadata.state==ProviderAccountState::verified};}
};
// A passive native view. Refresh reads local metrics only; account metadata is injected from the
// existing explicit account check. Opening this view cannot launch a CLI, browser or sign-in.
class UsagePanel:public std::enable_shared_from_this<UsagePanel> {
public:
    static std::shared_ptr<UsagePanel> create(std::shared_ptr<UsageStore> store,std::vector<UsageLabel> projects={},std::vector<UsageLabel> threads={},std::vector<UsageAccountStatus> accounts={}){
        if(!store)throw std::invalid_argument("Usage needs its local metric store");auto result=std::shared_ptr<UsagePanel>(new UsagePanel(std::move(store),std::move(projects),std::move(threads),std::move(accounts)));result->build();result->refresh();return result;
    }
    winrt::Microsoft::UI::Xaml::Controls::Grid view()const{return root_;}
    void close(){closed_=true;}
    void set_recording_warning(std::string value){if(closed_)return;recording_warning_=std::move(value);render();}
    void set_accounts(std::vector<UsageAccountStatus> value){if(closed_)return;if(value.size()>100)throw std::invalid_argument("Usage accounts exceed their UI bound");accounts_=std::move(value);render();}
    void refresh(){if(closed_)return;try{store_->open();error_.clear();render();}catch(...){error_="Local usage history could not be read. The existing file was preserved.";render_error();}}
    UsageFilter filter()const{
        UsageFilter result;const auto provider=providers_.SelectedIndex();if(provider>0&&provider<=6)result.provider=provider_ids_[static_cast<std::size_t>(provider-1)];
        const auto project=projects_.SelectedIndex();if(project>0&&static_cast<std::size_t>(project)<=project_labels_.size())result.project_id=project_labels_[static_cast<std::size_t>(project-1)].id;
        const auto thread=threads_.SelectedIndex();if(thread>0&&static_cast<std::size_t>(thread)<=thread_labels_.size())result.thread_id=thread_labels_[static_cast<std::size_t>(thread-1)].id;
        const auto days=period_.SelectedIndex()==0?7:period_.SelectedIndex()==1?30:0;result.until_ms=UsageStore::now_ms()+60000;result.since_ms=days?result.until_ms-60000-static_cast<std::int64_t>(days)*86400000:0;return result;
    }
    UsageTotals displayed_totals()const{return totals_;}
private:
    std::shared_ptr<UsageStore> store_;std::vector<UsageLabel> project_labels_,thread_labels_;std::vector<UsageAccountStatus> accounts_;UsageTotals totals_;std::string error_,recording_warning_;bool closed_{},building_{};
    const std::vector<std::string> provider_ids_{"codex","claude","opencode","cursor","grok","antigravity"};
    winrt::Microsoft::UI::Xaml::Controls::Grid root_{nullptr};winrt::Microsoft::UI::Xaml::Controls::StackPanel body_{nullptr},rows_{nullptr},account_rows_{nullptr};
    winrt::Microsoft::UI::Xaml::Controls::ComboBox providers_{nullptr},projects_{nullptr},threads_{nullptr},period_{nullptr};
    winrt::Microsoft::UI::Xaml::Controls::TextBlock summary_{nullptr},cost_{nullptr},coverage_{nullptr},status_{nullptr};
    UsagePanel(std::shared_ptr<UsageStore> store,std::vector<UsageLabel> projects,std::vector<UsageLabel> threads,std::vector<UsageAccountStatus> accounts):store_(std::move(store)),project_labels_(std::move(projects)),thread_labels_(std::move(threads)),accounts_(std::move(accounts)){
        if(project_labels_.size()>1000||thread_labels_.size()>1000||accounts_.size()>100)throw std::invalid_argument("Usage labels exceed their UI bound");for(auto* labels:{&project_labels_,&thread_labels_})for(auto& label:*labels){label.id=usage_guid(label.id);usage_text(label.label,512);}
    }
    static winrt::Microsoft::UI::Xaml::Controls::TextBlock text(const std::wstring& source,const wchar_t* id=nullptr){namespace ui=winrt::Microsoft::UI::Xaml::Controls;ui::TextBlock result;result.Text(source);result.TextWrapping(winrt::Microsoft::UI::Xaml::TextWrapping::Wrap);if(id)winrt::Microsoft::UI::Xaml::Automation::AutomationProperties::SetAutomationId(result,id);return result;}
    static std::wstring amount(double value){if(value>0&&value<0.0001)return L"<$0.0001 USD";std::wostringstream result;result.imbue(std::locale::classic());result<<L"$"<<std::fixed<<std::setprecision(4)<<value<<L" USD";return result.str();}
    static std::wstring provider_name(const std::string& id){if(id=="codex")return L"Codex";if(id=="claude")return L"Claude Code";if(id=="opencode")return L"OpenCode";if(id=="cursor")return L"Cursor";if(id=="grok")return L"Grok";if(id=="antigravity")return L"Antigravity";return L"Unknown provider";}
    void build(){
        namespace ui=winrt::Microsoft::UI::Xaml::Controls;namespace xaml=winrt::Microsoft::UI::Xaml;building_=true;root_=ui::Grid{};xaml::Automation::AutomationProperties::SetAutomationId(root_,L"UsagePanel");ui::ScrollViewer scroll;root_.Children().Append(scroll);body_=ui::StackPanel{};body_.Spacing(10);body_.Padding({16,16,16,16});scroll.Content(body_);
        body_.Children().Append(text(std::wstring(ui_text(L"Usage"))));body_.Children().Append(text(std::wstring(ui_text(L"Only usage reported by this app's provider sessions is included. Context snapshots and account balances are separate from turn totals."))));
        body_.Children().Append(text(std::wstring(ui_text(L"Local history retains the most recent 10,000 recorded turns. All-time totals cover retained history."))));
        const auto combo=[&](const wchar_t* title,const wchar_t* id){ui::ComboBox box;box.Header(winrt::box_value(ui_text(title)));box.HorizontalAlignment(xaml::HorizontalAlignment::Stretch);xaml::Automation::AutomationProperties::SetAutomationId(box,id);body_.Children().Append(box);return box;};
        providers_=combo(L"Provider",L"UsageProvider");providers_.Items().Append(winrt::box_value(ui_text(L"All providers")));for(const auto& provider:provider_ids_)providers_.Items().Append(winrt::box_value(provider_name(provider)));providers_.SelectedIndex(0);
        projects_=combo(L"Project",L"UsageProject");projects_.Items().Append(winrt::box_value(ui_text(L"All projects")));for(const auto& label:project_labels_)projects_.Items().Append(winrt::box_value(winrt::to_hstring(label.label)));projects_.SelectedIndex(0);
        threads_=combo(L"Thread",L"UsageThread");threads_.Items().Append(winrt::box_value(ui_text(L"All threads")));for(const auto& label:thread_labels_)threads_.Items().Append(winrt::box_value(winrt::to_hstring(label.label)));threads_.SelectedIndex(0);
        period_=combo(L"Period",L"UsagePeriod");for(const auto* item:{L"Last 7 days",L"Last 30 days",L"All recorded time"})period_.Items().Append(winrt::box_value(ui_text(item)));period_.SelectedIndex(1);
        ui::Button refresh;refresh.Content(winrt::box_value(ui_text(L"Refresh local totals")));xaml::Automation::AutomationProperties::SetAutomationId(refresh,L"RefreshUsage");refresh.Click([weak=weak_from_this()](const auto&,const auto&){if(const auto self=weak.lock())self->refresh();});body_.Children().Append(refresh);
        summary_=text(L"",L"UsageTokenSummary");cost_=text(L"",L"UsageCostSummary");coverage_=text(L"",L"UsageCoverage");status_=text(L"",L"UsageStatus");for(const auto& control:{summary_,cost_,coverage_,status_})body_.Children().Append(control);
        rows_=ui::StackPanel{};rows_.Spacing(6);xaml::Automation::AutomationProperties::SetAutomationId(rows_,L"UsageRows");body_.Children().Append(rows_);account_rows_=ui::StackPanel{};account_rows_.Spacing(6);xaml::Automation::AutomationProperties::SetAutomationId(account_rows_,L"UsageAccounts");body_.Children().Append(account_rows_);
        for(const auto& control:{providers_,projects_,threads_,period_})control.SelectionChanged([weak=weak_from_this()](const auto&,const auto&){if(const auto self=weak.lock();self&&!self->building_&&!self->closed_)self->render();});building_=false;
    }
    void render_error(){totals_={};summary_.Text(ui_text(L"Reported tokens: Unavailable"));cost_.Text(ui_text(L"Reported cost: Unavailable"));coverage_.Text(L"");status_.Text(winrt::to_hstring(error_));rows_.Children().Clear();render_accounts();}
    void render(){
        if(closed_)return;if(!error_.empty()){render_error();return;}const auto selected=filter();totals_=store_->totals(selected);
        summary_.Text(totals_.token_records?winrt::hstring(std::wstring(ui_text(L"Reported tokens: "))+std::to_wstring(totals_.tokens.total())+L" · "+std::to_wstring(totals_.tokens.input+totals_.tokens.cache_read+totals_.tokens.cache_write)+L" input · "+std::to_wstring(totals_.tokens.output)+L" output"):ui_text(L"Reported tokens: Unavailable"));
        cost_.Text(totals_.cost_records?winrt::hstring(std::wstring(ui_text(L"Reported cost: "))+amount(totals_.reported_cost_usd)):ui_text(L"Reported cost: Unavailable"));
        coverage_.Text(winrt::hstring(std::to_wstring(totals_.records)+L" recorded turns · "+std::to_wstring(totals_.token_records)+L" with additive token totals · "+std::to_wstring(totals_.snapshot_records)+L" with snapshots only"));status_.Text(!recording_warning_.empty()?winrt::to_hstring(recording_warning_):totals_.records?ui_text(L"Unreported usage is excluded. No subscription charge or estimated model price is inferred."):ui_text(L"No provider usage has been recorded for this selection."));
        rows_.Children().Clear();for(const auto& row:store_->rows(UsageDimension::provider,selected))rows_.Children().Append(text(provider_name(row.id)+L": "+(row.totals.token_records?std::to_wstring(row.totals.tokens.total())+L" reported tokens":std::wstring(ui_text(L"Token totals unavailable")))+L" · "+(row.totals.cost_records?amount(row.totals.reported_cost_usd):std::wstring(ui_text(L"Cost unavailable")))));
        const auto snapshot=store_->records(selected);if(!snapshot.empty()){const auto& latest=snapshot.back();if(latest.context_tokens)rows_.Children().Append(text(std::wstring(ui_text(L"Latest context snapshot: "))+std::to_wstring(*latest.context_tokens)+(latest.context_window?L" / "+std::to_wstring(*latest.context_window):L"")+L" tokens"));}render_accounts();
    }
    void render_accounts(){
        account_rows_.Children().Clear();account_rows_.Children().Append(text(std::wstring(ui_text(L"Provider accounts"))));const auto selected=filter();unsigned shown{};
        for(const auto& account:accounts_){if(!selected.provider.empty()&&selected.provider!=account.provider)continue;if(!usage_provider(account.provider))continue;try{usage_text(account.label,512,true);usage_text(account.version,128,true);}catch(...){continue;}const bool verified=account.verified&&!account.account_scope.empty()&&account.account_scope.size()==64&&account.account_scope.find_first_not_of("0123456789abcdef")==std::string::npos&&!account.source.empty();
            auto line=provider_name(account.provider)+L" · "+winrt::to_hstring(account.label).c_str()+L" · "+std::wstring(verified?ui_text(L"Verified account metadata"):ui_text(L"Account status unavailable"));if(!account.version.empty())line+=L" · "+winrt::to_hstring(account.version);account_rows_.Children().Append(text(line));account_rows_.Children().Append(text(std::wstring(ui_text(L"Balance: Unavailable · Rate limits: Unavailable")),L"UsageAccountAvailability"));++shown;}
        if(!shown)account_rows_.Children().Append(text(std::wstring(ui_text(L"Account status, balances and rate limits are unavailable. Check a profile explicitly in Accounts.")),L"UsageAccountAvailability"));
    }
};
} // namespace coincide
