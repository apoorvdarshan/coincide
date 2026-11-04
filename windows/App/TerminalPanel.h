#pragma once
#include "../Core/TerminalScreen.h"
#include "../Runtime/ConPtySession.h"
#include "NativeStrings.h"
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Documents.h>
#include <winrt/Microsoft.UI.Xaml.Shapes.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>
#include <winrt/Microsoft.UI.Xaml.Markup.h>
#include <winrt/Microsoft.UI.Xaml.Data.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Microsoft.UI.Xaml.Input.h>
#include <winrt/Microsoft.UI.Dispatching.h>
#include <winrt/Windows.UI.Text.h>
#include <winrt/Windows.UI.h>
#include <winrt/Windows.UI.Xaml.Interop.h>
#include <winrt/Windows.ApplicationModel.DataTransfer.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.System.h>
#include <future>
#include <functional>
#include <unordered_map>

namespace coincide {
namespace terminal_ui {
namespace xaml=winrt::Microsoft::UI::Xaml;
namespace ui=xaml::Controls;
namespace docs=xaml::Documents;
using Inspectable=winrt::Windows::Foundation::IInspectable;
using XamlType=winrt::Windows::UI::Xaml::Interop::TypeName;
using TypeKind=winrt::Windows::UI::Xaml::Interop::TypeKind;
inline void identify(const xaml::DependencyObject& value,const wchar_t* id){xaml::Automation::AutomationProperties::SetAutomationId(value,id);}
inline std::uint32_t rgb(const TerminalColor& color,bool foreground){
    if(color.kind==TerminalColor::Kind::rgb)return color.value&0xffffffU;
    if(color.kind==TerminalColor::Kind::default_color)return foreground?0xd4d4d4U:0x0c0c0cU;
    constexpr std::uint32_t palette[]{0x0c0c0c,0xc50f1f,0x13a10e,0xc19c00,0x0037da,0x881798,0x3a96dd,0xcccccc,
        0x767676,0xe74856,0x16c60c,0xf9f1a5,0x3b78ff,0xb4009e,0x61d6d6,0xf2f2f2};
    const auto index=std::min(color.value,255U);
    if(index<16)return palette[index];
    if(index>=232){const auto gray=8+(index-232)*10;return(gray<<16)|(gray<<8)|gray;}
    constexpr std::uint32_t levels[]{0,95,135,175,215,255};
    const auto cube=index-16;return(levels[cube/36]<<16)|(levels[(cube/6)%6]<<8)|levels[cube%6];
}
inline xaml::Media::SolidColorBrush brush(std::uint32_t color,std::uint8_t alpha=255){
    return xaml::Media::SolidColorBrush(winrt::Windows::UI::Color{alpha,static_cast<std::uint8_t>(color>>16),static_cast<std::uint8_t>(color>>8),static_cast<std::uint8_t>(color)});
}
struct Row;
inline Inspectable row_content(const Inspectable& target);
struct RowProperty:winrt::implements<RowProperty,xaml::Data::ICustomProperty>{
    explicit RowProperty(bool content=false):content_(content){}
    XamlType Type()const{return{content_?L"Object":L"String",TypeKind::Primitive};}
    winrt::hstring Name()const{return content_?L"Content":L"Text";}
    Inspectable GetValue(const Inspectable& target)const{return content_?row_content(target):winrt::box_value(target.as<xaml::Data::ICustomPropertyProvider>().GetStringRepresentation());}
    bool CanRead()const{return true;}bool CanWrite()const{return false;}
    void SetValue(const Inspectable&,const Inspectable&)const{throw winrt::hresult_access_denied();}
    Inspectable GetIndexedValue(const Inspectable&,const Inspectable&)const{throw winrt::hresult_not_implemented();}
    void SetIndexedValue(const Inspectable&,const Inspectable&,const Inspectable&)const{throw winrt::hresult_not_implemented();}
private:bool content_{};
};
// The immutable identity avoids equal-row lookup cycles and builds a visual only for realized rows.
struct Row:winrt::implements<Row,xaml::Data::ICustomPropertyProvider>{
    Row(TerminalLine cells,double cell_width,double line_height,std::optional<std::size_t> cursor,std::shared_ptr<std::string> selected)
        :cells_(std::move(cells)),cell_width_(cell_width),line_height_(line_height),cursor_(cursor),selected_(std::move(selected)){}
    xaml::Data::ICustomProperty GetCustomProperty(const winrt::hstring& name)const{
        if(name==L"Text")return winrt::make<RowProperty>();if(name==L"Content")return winrt::make<RowProperty>(true);return nullptr;
    }
    xaml::Data::ICustomProperty GetIndexedProperty(const winrt::hstring&,const XamlType&)const{return nullptr;}
    winrt::hstring GetStringRepresentation()const{return winrt::to_hstring(TerminalScreen::line_text(cells_));}
    XamlType Type()const{return{L"Coincide.TerminalRow",TypeKind::Custom};}
    Inspectable content(){
        if(content_)return content_;
        content_=ui::Grid{};content_.Width(static_cast<double>(cells_.size())*cell_width_);content_.Height(line_height_);
        content_.DataContext(winrt::box_value(false));identify(content_,L"TerminalRow");
        xaml::Automation::AutomationProperties::SetName(content_,GetStringRepresentation());
        ui::Canvas backgrounds;backgrounds.IsHitTestVisible(false);content_.Children().Append(backgrounds);
        ui::RichTextBlock text;text.FontFamily(xaml::Media::FontFamily(L"Consolas"));text.FontSize(14);
        text.LineHeight(line_height_);text.LineStackingStrategy(xaml::LineStackingStrategy::BlockLineHeight);
        text.TextWrapping(xaml::TextWrapping::NoWrap);text.IsTextSelectionEnabled(true);identify(text,L"TerminalRowText");
        text.SelectionChanged([selected=selected_](const auto& sender,const auto&){
            const auto value=sender.template as<ui::RichTextBlock>().SelectedText();if(!value.empty())*selected=winrt::to_string(value);
        });
        docs::Paragraph paragraph;paragraph.Margin({0,0,0,0});
        for(std::size_t first=0;first<cells_.size();){
            auto last=first+1;while(last<cells_.size()&&cells_[last].style==cells_[first].style)++last;
            const auto& style=cells_[first].style;
            auto foreground=rgb(style.foreground,true),background=rgb(style.background,false);
            if(style.inverse)std::swap(foreground,background);if(style.conceal)foreground=background;
            if(background!=0x0c0c0cU){
                xaml::Shapes::Rectangle fill;fill.Width(static_cast<double>(last-first)*cell_width_);fill.Height(line_height_);fill.Fill(brush(background));
                ui::Canvas::SetLeft(fill,static_cast<double>(first)*cell_width_);backgrounds.Children().Append(fill);
            }
            std::string value;for(auto column=first;column<last;++column)if(!cells_[column].continuation)value+=cells_[column].text;
            docs::Run run;run.Text(winrt::to_hstring(value));run.Foreground(brush(foreground,style.dim?140:255));
            if(style.bold)run.FontWeight(winrt::Windows::UI::Text::FontWeights::Bold());
            if(style.italic)run.FontStyle(winrt::Windows::UI::Text::FontStyle::Italic);
            auto decoration=winrt::Windows::UI::Text::TextDecorations::None;
            if(style.underline)decoration=decoration|winrt::Windows::UI::Text::TextDecorations::Underline;
            if(style.strikethrough)decoration=decoration|winrt::Windows::UI::Text::TextDecorations::Strikethrough;
            run.TextDecorations(decoration);paragraph.Inlines().Append(run);first=last;
        }
        text.Blocks().Append(paragraph);content_.Children().Append(text);
        if(cursor_&&*cursor_<cells_.size()){
            ui::Canvas overlay;overlay.IsHitTestVisible(false);xaml::Shapes::Rectangle cursor;
            cursor.Width(cell_width_);cursor.Height(line_height_);cursor.Fill(brush(0xd4d4d4,90));
            ui::Canvas::SetLeft(cursor,static_cast<double>(*cursor_)*cell_width_);overlay.Children().Append(cursor);content_.Children().Append(overlay);
        }
        return content_;
    }
private:
    TerminalLine cells_;double cell_width_,line_height_;std::optional<std::size_t> cursor_;
    std::shared_ptr<std::string> selected_;ui::Grid content_{nullptr};
};
inline Inspectable row_content(const Inspectable& target){return winrt::get_self<Row>(target.as<xaml::Data::ICustomPropertyProvider>())->content();}
} // namespace terminal_ui

struct TerminalPaneSnapshot{std::string id,tab_id,thread_id,title,status;bool running{},starting{};std::size_t columns{},rows{};};
struct TerminalReadSnapshot{TerminalPaneSnapshot pane;std::string text;bool truncated{};};
class TerminalPanel:public std::enable_shared_from_this<TerminalPanel>{
public:
    static std::shared_ptr<TerminalPanel> create(std::filesystem::path base_data_path,bool fixture_mode=false){
        if(!base_data_path.is_absolute())throw std::invalid_argument("The terminal needs an absolute data directory");
        auto result=std::shared_ptr<TerminalPanel>(new TerminalPanel(std::move(base_data_path),fixture_mode));result->build_view();return result;
    }
    terminal_ui::ui::Grid view()const{return root_;}
    void set_command_guard(std::function<bool(const std::string&,const std::filesystem::path&)> guard){command_guard_=std::move(guard);}
    void select_thread(std::string id,std::filesystem::path cwd){
        if(id.empty()){selected_thread_.clear();show_active();return;}
        if(id.size()!=36&&id.size()!=38)throw std::invalid_argument("Invalid terminal conversation identity");
        (void)winrt::guid{winrt::to_hstring(id)};
        selected_thread_=std::move(id);auto& state=threads_[selected_thread_];
        if(cwd.empty()){cwd=base_/L"workspaces"/winrt::to_hstring(selected_thread_).c_str();std::filesystem::create_directories(cwd);}
        if(!cwd.is_absolute())throw std::invalid_argument("The terminal needs an absolute working folder");
        state.cwd=std::move(cwd);if(visible_&&state.tabs.empty())create_tab(false);else refresh_tabs();
    }
    void set_visible(bool value){
        visible_=value;root_.Visibility(value?terminal_ui::xaml::Visibility::Visible:terminal_ui::xaml::Visibility::Collapsed);
        if(value&&!selected_thread_.empty()&&threads_[selected_thread_].tabs.empty())create_tab(true);
        else if(value){show_active();resize_visible();}
    }
    std::string new_tab(){return create_tab(true);}
    std::string split(){
        auto tab=active_tab();if(!tab){create_tab(true);tab=active_tab();}
        if(!tab)return{};
        if(tab->panes.size()>=4)throw std::runtime_error("This terminal tab already has four panes");
        auto pane=create_pane(tab->thread_id,threads_.at(tab->thread_id).cwd,true);tab->panes.push_back(pane);tab->active=pane->id;show_active();return pane->id;
    }
    void close_tab(std::string id={}){
        if(id.empty()){const auto tab=active_tab();if(!tab)return;id=tab->id;}
        for(auto& [thread,state]:threads_){
            (void)thread;const auto at=std::find_if(state.tabs.begin(),state.tabs.end(),[&](const auto& tab){return tab->id==id;});
            if(at==state.tabs.end())continue;
            for(const auto& pane:(*at)->panes)retire(pane);
            state.tabs.erase(at);if(state.selected==id)state.selected=state.tabs.empty()?"":state.tabs.front()->id;refresh_tabs();return;
        }
    }
    void close_thread(const std::string& id){
        const auto state=threads_.find(id);if(state==threads_.end())return;
        for(const auto& tab:state->second.tabs)for(const auto& pane:tab->panes)retire(pane);
        threads_.erase(state);if(selected_thread_==id){selected_thread_.clear();refresh_tabs();}
    }
    std::vector<TerminalPaneSnapshot> panes(const std::string& id)const{
        std::vector<TerminalPaneSnapshot> result;const auto state=threads_.find(id);if(state==threads_.end())return result;
        for(const auto& tab:state->second.tabs)for(const auto& pane:tab->panes)result.push_back({pane->id,tab->id,id,pane->screen.title(),pane->status,
            pane->session&&pane->session->running(),pane->starting.valid(),pane->screen.columns(),pane->screen.rows()});return result;
    }
    TerminalReadSnapshot read(const std::string& thread,const std::string& pane_id,std::size_t maximum=65536)const{
        if(closed_||maximum<1||maximum>65536)throw std::invalid_argument("Invalid terminal read limit");
        const auto state=threads_.find(thread);if(state==threads_.end())throw std::invalid_argument("This conversation has no terminal");
        for(const auto& tab:state->second.tabs)for(const auto& pane:tab->panes)if(pane->id==pane_id){
            TerminalReadSnapshot result{{pane->id,tab->id,thread,pane->screen.title(),pane->status,pane->session&&pane->session->running(),pane->starting.valid(),pane->screen.columns(),pane->screen.rows()},{},false};
            std::vector<std::string> tail;std::size_t bytes{};
            const auto append=[&](const auto& lines){for(auto row=lines.rbegin();row!=lines.rend();++row){if(bytes>=maximum){result.truncated=true;break;}auto text=TerminalScreen::line_text(*row);text+='\n';bytes+=text.size();tail.push_back(std::move(text));}};
            append(pane->screen.lines());append(pane->screen.scrollback());result.text.reserve(bytes);for(auto line=tail.rbegin();line!=tail.rend();++line)result.text+=*line;
            if(result.text.size()>maximum){auto remove=result.text.size()-maximum;while(remove<result.text.size()&&(static_cast<unsigned char>(result.text[remove])&0xc0)==0x80)++remove;result.text.erase(0,remove);result.truncated=true;}return result;
        }
        throw std::invalid_argument("The terminal pane does not belong to this conversation");
    }
    bool interrupt(const std::string& thread,const std::string& pane_id){
        if(closed_)return false;const auto state=threads_.find(thread);if(state==threads_.end())return false;
        for(const auto& tab:state->second.tabs)for(const auto& pane:tab->panes)if(pane->id==pane_id){if(!pane->session||!pane->session->running())return false;return send(pane,std::string(1,'\x03'));}return false;
    }
    void close()noexcept{
        if(closed_)return;closed_=true;try{timer_.Stop();}catch(...){}
        for(auto& [id,state]:threads_){(void)id;for(const auto& tab:state.tabs)for(const auto& pane:tab->panes){pane->closed=true;if(pane->session)pane->session->stop();}}
        for(const auto& pane:retired_)if(pane->session)pane->session->stop();
        for(auto& [id,state]:threads_){(void)id;for(const auto& tab:state.tabs)for(const auto& pane:tab->panes)finish_pane(pane);}
        for(const auto& pane:retired_)finish_pane(pane);
        retired_.clear();threads_.clear();
    }
    ~TerminalPanel(){close();}

private:
    struct Pane{
        std::string id,thread_id,status,pending_input;
        std::filesystem::path cwd;
        TerminalScreen screen;
        std::unique_ptr<ConPtySession> session;
        std::future<std::unique_ptr<ConPtySession>> starting;
        std::deque<std::string> pending_output;
        std::size_t pending_bytes{},pending_offset{};
        bool closed{},composing{},clearing{},dirty{true},exit_pending{},exited{},pending_focus{},failed{};
        DWORD exit_code{};double cell_width{8.4},line_height{20};
        std::shared_ptr<std::string> selection=std::make_shared<std::string>();
        terminal_ui::ui::Grid root{nullptr};terminal_ui::ui::ListView output{nullptr};terminal_ui::ui::TextBox input{nullptr};
        terminal_ui::ui::TextBlock status_view{nullptr};
        std::vector<TerminalLine> rendered;
        std::optional<std::size_t> rendered_cursor;
        bool blink_visible{true};
    };
    struct Tab{std::string id,thread_id,active;std::vector<std::shared_ptr<Pane>> panes;};
    struct ThreadTabs{std::filesystem::path cwd;std::vector<std::shared_ptr<Tab>> tabs;std::string selected;};
    std::filesystem::path base_;bool fixture_{},visible_{},closed_{},refreshing_{};std::string selected_thread_;
    std::unordered_map<std::string,ThreadTabs> threads_;std::vector<std::shared_ptr<Pane>> retired_;
    std::function<bool(const std::string&,const std::filesystem::path&)> command_guard_;
    std::vector<std::string> displayed_tabs_;
    terminal_ui::ui::Grid root_{nullptr},panes_view_{nullptr};terminal_ui::ui::ComboBox tabs_{nullptr};terminal_ui::ui::TextBlock status_{nullptr};
    winrt::Microsoft::UI::Dispatching::DispatcherQueueTimer timer_{nullptr};
    static constexpr std::size_t session_limit=32,pending_limit=4*1024*1024;

    TerminalPanel(std::filesystem::path base,bool fixture):base_(std::move(base)),fixture_(fixture){}
    static std::string identity(){winrt::guid id;winrt::check_hresult(CoCreateGuid(reinterpret_cast<GUID*>(&id)));return winrt::to_string(winrt::to_hstring(id));}
    std::shared_ptr<Tab> active_tab()const{
        const auto state=threads_.find(selected_thread_);if(state==threads_.end())return{};
        const auto at=std::find_if(state->second.tabs.begin(),state->second.tabs.end(),[&](const auto& tab){return tab->id==state->second.selected;});
        return at==state->second.tabs.end()?std::shared_ptr<Tab>{}:*at;
    }
    std::shared_ptr<Pane> active_pane()const{
        const auto tab=active_tab();if(!tab||tab->panes.empty())return{};
        const auto at=std::find_if(tab->panes.begin(),tab->panes.end(),[&](const auto& pane){return pane->id==tab->active;});
        return at==tab->panes.end()?tab->panes.front():*at;
    }
    std::size_t session_count()const{
        auto count=retired_.size();for(const auto& [id,state]:threads_){(void)id;for(const auto& tab:state.tabs)count+=tab->panes.size();}return count;
    }
    void show_error(const std::string& value){if(status_)status_.Text(winrt::to_hstring(value));}
    bool command_allowed(const std::string& thread,const std::filesystem::path& cwd)const noexcept{try{return !closed_&&(!command_guard_||command_guard_(thread,cwd));}catch(...){return false;}}
    terminal_ui::ui::Button make_button(const wchar_t* text,const wchar_t* id,std::function<void(TerminalPanel&)> action){
        terminal_ui::ui::Button value;value.Content(winrt::box_value(ui_text(text)));terminal_ui::identify(value,id);
        value.Click([weak=weak_from_this(),action=std::move(action)](const auto&,const auto&){if(const auto self=weak.lock())try{action(*self);}catch(const std::exception& error){self->show_error(error.what());}catch(const winrt::hresult_error& error){self->show_error(winrt::to_string(error.message()));}});
        return value;
    }
    void build_view(){
        namespace xaml=terminal_ui::xaml;namespace ui=terminal_ui::ui;
        root_=ui::Grid{};root_.RowSpacing(6);root_.Visibility(xaml::Visibility::Collapsed);terminal_ui::identify(root_,L"TerminalPanel");
        for(const auto unit:{xaml::GridUnitType::Auto,xaml::GridUnitType::Star,xaml::GridUnitType::Auto}){ui::RowDefinition row;row.Height({1,unit});root_.RowDefinitions().Append(row);}
        ui::StackPanel toolbar;toolbar.Orientation(ui::Orientation::Horizontal);toolbar.Spacing(6);
        tabs_=ui::ComboBox{};tabs_.MinWidth(150);tabs_.MaxWidth(300);terminal_ui::identify(tabs_,L"TerminalTabs");
        tabs_.SelectionChanged([weak=weak_from_this()](const auto&,const auto&){if(const auto self=weak.lock();self&&!self->refreshing_){const auto at=self->tabs_.SelectedIndex();if(at>=0&&static_cast<std::size_t>(at)<self->displayed_tabs_.size()){self->threads_.at(self->selected_thread_).selected=self->displayed_tabs_[at];self->show_active();}}});
        toolbar.Children().Append(tabs_);toolbar.Children().Append(make_button(L"New Tab",L"TerminalNewTab",[](auto& self){self.new_tab();}));
        toolbar.Children().Append(make_button(L"Split",L"TerminalSplit",[](auto& self){self.split();}));
        toolbar.Children().Append(make_button(L"Close Tab",L"TerminalCloseTab",[](auto& self){self.close_tab();}));
        toolbar.Children().Append(make_button(L"Paste",L"TerminalPaste",[](auto& self){if(const auto pane=self.active_pane())self.paste(pane);}));
        toolbar.Children().Append(make_button(L"Copy",L"TerminalCopy",[](auto& self){if(const auto pane=self.active_pane())self.copy(pane);}));
        toolbar.Children().Append(make_button(L"Stop",L"TerminalStop",[](auto& self){if(const auto pane=self.active_pane();pane&&pane->session)pane->session->stop();}));
        root_.Children().Append(toolbar);panes_view_=ui::Grid{};panes_view_.ColumnSpacing(4);panes_view_.RowSpacing(4);ui::Grid::SetRow(panes_view_,1);root_.Children().Append(panes_view_);
        status_=ui::TextBlock{};status_.Text(ui_text(L"Open a terminal for this conversation."));status_.TextWrapping(xaml::TextWrapping::Wrap);terminal_ui::identify(status_,L"TerminalPanelStatus");ui::Grid::SetRow(status_,2);root_.Children().Append(status_);
        timer_=root_.DispatcherQueue().CreateTimer();timer_.Interval(std::chrono::milliseconds(40));
        timer_.Tick([weak=weak_from_this()](const auto&,const auto&){if(const auto self=weak.lock())self->tick();});timer_.Start();
    }
    TerminalLaunch options(const std::shared_ptr<Pane>& pane){
        TerminalLaunch result;result.cwd=pane->cwd;
        if(!std::filesystem::is_directory(result.cwd))throw std::runtime_error("The terminal working folder is unavailable.");
        wchar_t path[32768]{};
        if(fixture_){
            if(!GetModuleFileNameW(nullptr,path,32768))throw std::runtime_error("Cannot locate the terminal fixture");
            const auto executable=std::filesystem::path(path);
            result.executable=executable.parent_path().parent_path().parent_path()/L"core-x64"/executable.parent_path().filename()/L"CoincideWorkspaceTests.exe";
            if(!std::filesystem::is_regular_file(result.executable))throw std::runtime_error("Build the console terminal fixture first.");
            result.arguments={L"--terminal-fixture",L"interactive"};
        }else{
            const auto length=GetSystemDirectoryW(path,32768);if(!length||length>=32768)throw std::runtime_error("Cannot locate the Windows shell");
            const auto system=std::filesystem::path(path);result.executable=system/L"WindowsPowerShell"/L"v1.0"/L"powershell.exe";
            if(std::filesystem::is_regular_file(result.executable))result.arguments={L"-NoLogo",L"-NoProfile"};
            else{result.executable=system/L"cmd.exe";result.arguments={L"/D"};}
        }
        return result;
    }
    std::shared_ptr<Pane> create_pane(const std::string& thread,const std::filesystem::path& cwd,bool focus){
        if(!command_allowed(thread,cwd))throw std::runtime_error("Wait for the repository operation to finish before starting a terminal.");
        if(session_count()>=session_limit)throw std::runtime_error("Close an existing terminal before opening another session.");
        auto pane=std::make_shared<Pane>();pane->id=identity();pane->thread_id=thread;pane->cwd=cwd;pane->pending_focus=focus;
        pane->status=winrt::to_string(ui_text(L"Starting terminal…"));
        build_pane(pane);auto launch=options(pane);
        pane->starting=std::async(std::launch::async,[launch=std::move(launch)]()mutable{return ConPtySession::start(std::move(launch));});return pane;
    }
    std::string create_tab(bool focus){
        if(closed_||selected_thread_.empty())return{};
        auto& state=threads_.at(selected_thread_);if(state.tabs.size()>=8)throw std::runtime_error("This conversation already has eight terminal tabs.");
        auto tab=std::make_shared<Tab>();tab->id=identity();tab->thread_id=selected_thread_;
        auto pane=create_pane(selected_thread_,state.cwd,focus);tab->active=pane->id;tab->panes.push_back(pane);
        state.tabs.push_back(tab);state.selected=tab->id;refresh_tabs();return tab->id;
    }
    void refresh_tabs(){
        refreshing_=true;tabs_.Items().Clear();displayed_tabs_.clear();
        const auto state=threads_.find(selected_thread_);
        if(state!=threads_.end())for(std::size_t i=0;i<state->second.tabs.size();++i){
            const auto& tab=state->second.tabs[i];auto title=ui_text(L"Terminal")+L" "+winrt::to_hstring(i+1);
            if(!tab->panes.empty()&&!tab->panes.front()->screen.title().empty())title=title+L" — "+winrt::to_hstring(tab->panes.front()->screen.title());
            displayed_tabs_.push_back(tab->id);tabs_.Items().Append(winrt::box_value(title));
            if(tab->id==state->second.selected)tabs_.SelectedIndex(static_cast<std::int32_t>(i));
        }
        refreshing_=false;show_active();
    }
    void show_active(){
        namespace ui=terminal_ui::ui;
        panes_view_.Children().Clear();panes_view_.ColumnDefinitions().Clear();panes_view_.RowDefinitions().Clear();
        const auto tab=active_tab();if(!tab)return;
        const auto columns=tab->panes.size()>1?2U:1U,rows=tab->panes.size()>2?2U:1U;
        for(unsigned i=0;i<columns;++i)panes_view_.ColumnDefinitions().Append(ui::ColumnDefinition{});
        for(unsigned i=0;i<rows;++i)panes_view_.RowDefinitions().Append(ui::RowDefinition{});
        for(std::size_t i=0;i<tab->panes.size();++i){const auto& pane=tab->panes[i];ui::Grid::SetColumn(pane->root,static_cast<std::int32_t>(i%columns));ui::Grid::SetRow(pane->root,static_cast<std::int32_t>(i/columns));panes_view_.Children().Append(pane->root);pane->dirty=true;}
        resize_visible();
    }
    void build_pane(const std::shared_ptr<Pane>& pane){
        namespace xaml=terminal_ui::xaml;namespace ui=terminal_ui::ui;
        pane->root=ui::Grid{};pane->root.Background(terminal_ui::brush(0x0c0c0c));pane->root.Padding({4,4,4,4});pane->root.RowSpacing(4);
        terminal_ui::identify(pane->root,winrt::to_hstring("TerminalPane_"+pane->id).c_str());
        for(const auto unit:{xaml::GridUnitType::Star,xaml::GridUnitType::Auto,xaml::GridUnitType::Auto}){ui::RowDefinition row;row.Height({1,unit});pane->root.RowDefinitions().Append(row);}
        pane->output=ui::ListView{};pane->output.SelectionMode(ui::ListViewSelectionMode::None);pane->output.IsTabStop(false);
        pane->output.Padding({0,0,0,0});pane->output.HorizontalContentAlignment(xaml::HorizontalAlignment::Stretch);terminal_ui::identify(pane->output,L"TerminalOutput");
        ui::ScrollViewer::SetHorizontalScrollBarVisibility(pane->output,ui::ScrollBarVisibility::Auto);
        pane->output.ItemTemplate(xaml::Markup::XamlReader::Load(LR"(<DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><ContentPresenter Content="{Binding Content}"/></DataTemplate>)").as<xaml::DataTemplate>());
        xaml::Style item_style{winrt::xaml_typename<ui::ListViewItem>()};
        item_style.Setters().Append(xaml::Setter(xaml::FrameworkElement::HeightProperty(),winrt::box_value(pane->line_height)));
        item_style.Setters().Append(xaml::Setter(xaml::FrameworkElement::MinHeightProperty(),winrt::box_value(pane->line_height)));
        item_style.Setters().Append(xaml::Setter(ui::Control::PaddingProperty(),winrt::box_value(xaml::Thickness{0,0,0,0})));
        item_style.Setters().Append(xaml::Setter(xaml::FrameworkElement::MarginProperty(),winrt::box_value(xaml::Thickness{0,0,0,0})));
        pane->output.ItemContainerStyle(item_style);pane->root.Children().Append(pane->output);
        pane->input=ui::TextBox{};pane->input.PlaceholderText(ui_text(L"Terminal input"));pane->input.AcceptsReturn(false);
        pane->input.IsSpellCheckEnabled(false);pane->input.IsTextPredictionEnabled(false);
        pane->input.FontFamily(xaml::Media::FontFamily(L"Consolas"));terminal_ui::identify(pane->input,L"TerminalInput");ui::Grid::SetRow(pane->input,1);pane->root.Children().Append(pane->input);
        pane->status_view=ui::TextBlock{};pane->status_view.FontSize(11);pane->status_view.Foreground(terminal_ui::brush(0xcccccc));terminal_ui::identify(pane->status_view,L"TerminalStatus");ui::Grid::SetRow(pane->status_view,2);pane->root.Children().Append(pane->status_view);
        const auto weak_pane=std::weak_ptr<Pane>(pane);
        pane->input.TextCompositionStarted([weak_pane](const auto&,const auto&){if(const auto value=weak_pane.lock())value->composing=true;});
        pane->input.TextCompositionEnded([weak=weak_from_this(),weak_pane](const auto&,const auto&){if(const auto self=weak.lock())if(const auto value=weak_pane.lock()){value->composing=false;self->flush_text(value);}});
        pane->input.TextChanged([weak=weak_from_this(),weak_pane](const auto&,const auto&){if(const auto self=weak.lock())if(const auto value=weak_pane.lock())self->flush_text(value);});
        pane->input.KeyDown([weak=weak_from_this(),weak_pane](const auto&,const xaml::Input::KeyRoutedEventArgs& args){if(const auto self=weak.lock())if(const auto value=weak_pane.lock())try{self->key(value,args);}catch(const winrt::hresult_error& error){self->show_error(winrt::to_string(error.message()));}catch(const std::exception& error){self->show_error(error.what());}});
        pane->input.GotFocus([weak=weak_from_this(),weak_pane](const auto&,const auto&){if(const auto self=weak.lock())if(const auto value=weak_pane.lock()){value->selection->clear();if(const auto tab=self->active_tab())tab->active=value->id;}});
        pane->input.Loaded([weak=weak_from_this(),weak_pane](const auto&,const auto&){if(const auto self=weak.lock())if(const auto value=weak_pane.lock();value&&value->pending_focus&&self->visible_){value->pending_focus=false;value->input.Focus(xaml::FocusState::Programmatic);}});
        pane->output.SizeChanged([weak=weak_from_this(),weak_pane](const auto&,const auto&){if(const auto self=weak.lock())if(const auto value=weak_pane.lock())self->resize_pane(value);});
    }
    bool send(const std::shared_ptr<Pane>& pane,std::string bytes){
        if(closed_||pane->closed||pane->exited)return false;
        if(!command_allowed(pane->thread_id,pane->cwd)){pane->status=winrt::to_string(ui_text(L"Wait for the repository operation to finish before sending terminal input."));pane->dirty=true;return false;}
        bool accepted{};
        if(pane->session)accepted=pane->session->write(bytes);
        else if(pane->starting.valid()&&bytes.size()<=1024*1024-pane->pending_input.size()){pane->pending_input+=bytes;accepted=true;}
        if(!accepted){pane->status=winrt::to_string(ui_text(L"Terminal input limit reached or session closed."));pane->dirty=true;}
        return accepted;
    }
    void flush_text(const std::shared_ptr<Pane>& pane){
        if(pane->composing||pane->clearing||pane->closed)return;
        const auto text=pane->input.Text();if(text.empty())return;
        for(std::uint32_t i=0;i<text.size();++i){const auto ch=text[i];if(ch>=0xd800&&ch<=0xdbff){if(++i==text.size()||text[i]<0xdc00||text[i]>0xdfff)return;}else if(ch>=0xdc00&&ch<=0xdfff)return;}
        try{if(send(pane,winrt::to_string(text))){pane->clearing=true;pane->input.Text(L"");pane->clearing=false;}}catch(...){pane->clearing=false;}
    }
    static bool pressed(int key){return(GetKeyState(key)&0x8000)!=0;}
    void key(const std::shared_ptr<Pane>& pane,const terminal_ui::xaml::Input::KeyRoutedEventArgs& args){
        if(pane->composing)return;
        using Key=winrt::Windows::System::VirtualKey;
        const auto value=args.Key();const bool control=pressed(VK_CONTROL),shift=pressed(VK_SHIFT),alt=pressed(VK_MENU);
        if(control&&shift&&value==Key::C){args.Handled(true);copy(pane);return;}
        if(control&&value==Key::V&&!alt){args.Handled(true);paste(pane);return;}
        std::string bytes;const auto modifier=1+(shift?1:0)+(alt?2:0)+(control?4:0);
        const auto cursor_sequence=[&](char command){if(modifier>1)return std::string("\x1b[1;")+std::to_string(modifier)+command;return std::string(pane->screen.application_cursor_keys()?"\x1bO":"\x1b[")+command;};
        switch(value){
        case Key::Enter:bytes="\r";break;case Key::Escape:bytes="\x1b";break;case Key::Back:bytes="\x7f";break;
        case Key::Tab:bytes=shift?"\x1b[Z":"\t";break;
        case Key::Up:bytes=cursor_sequence('A');break;case Key::Down:bytes=cursor_sequence('B');break;
        case Key::Right:bytes=cursor_sequence('C');break;case Key::Left:bytes=cursor_sequence('D');break;
        case Key::Home:bytes=cursor_sequence('H');break;case Key::End:bytes=cursor_sequence('F');break;
        default:break;
        }
        const auto number=static_cast<std::uint32_t>(value);
        if(bytes.empty()&&control&&!alt&&number>=static_cast<std::uint32_t>(Key::A)&&number<=static_cast<std::uint32_t>(Key::Z))bytes.push_back(static_cast<char>(number-static_cast<std::uint32_t>(Key::A)+1));
        if(bytes.empty()&&control&&!alt&&value==Key::Space)bytes.push_back('\0');
        int tilde{};if(value==Key::Insert)tilde=2;else if(value==Key::Delete)tilde=3;else if(value==Key::PageUp)tilde=5;else if(value==Key::PageDown)tilde=6;
        if(number>=static_cast<std::uint32_t>(Key::F5)&&number<=static_cast<std::uint32_t>(Key::F12)){constexpr int codes[]{15,17,18,19,20,21,23,24};tilde=codes[number-static_cast<std::uint32_t>(Key::F5)];}
        if(tilde)bytes="\x1b["+std::to_string(tilde)+(modifier>1?";"+std::to_string(modifier):"")+"~";
        if(number>=static_cast<std::uint32_t>(Key::F1)&&number<=static_cast<std::uint32_t>(Key::F4)){const auto letter=static_cast<char>('P'+number-static_cast<std::uint32_t>(Key::F1));bytes=modifier>1?"\x1b[1;"+std::to_string(modifier)+letter:std::string("\x1bO")+letter;}
        if(!bytes.empty()){args.Handled(true);send(pane,std::move(bytes));}
    }
    winrt::fire_and_forget paste(std::shared_ptr<Pane> pane){
        const auto self=shared_from_this();
        try{
            const auto content=winrt::Windows::ApplicationModel::DataTransfer::Clipboard::GetContent();
            if(!content.Contains(winrt::Windows::ApplicationModel::DataTransfer::StandardDataFormats::Text()))co_return;
            const auto text=co_await content.GetTextAsync();if(self->closed_||pane->closed)co_return;
            auto bytes=winrt::to_string(text);if(pane->screen.bracketed_paste())bytes="\x1b[200~"+bytes+"\x1b[201~";
            self->send(pane,std::move(bytes));
        }catch(...){if(!self->closed_)self->show_error(winrt::to_string(ui_text(L"Could not read text from the clipboard.")));}
    }
    void copy(const std::shared_ptr<Pane>& pane){
        std::string text=*pane->selection;
        if(text.empty()){for(const auto& row:pane->screen.lines()){text+=TerminalScreen::line_text(row);text+='\n';}}
        winrt::Windows::ApplicationModel::DataTransfer::DataPackage data;data.SetText(winrt::to_hstring(text));winrt::Windows::ApplicationModel::DataTransfer::Clipboard::SetContent(data);
    }
    void resize_visible(){if(const auto tab=active_tab())for(const auto& pane:tab->panes)resize_pane(pane);}
    void resize_pane(const std::shared_ptr<Pane>& pane){
        if(!visible_||pane->closed||!pane->output.IsLoaded()||pane->thread_id!=selected_thread_)return;
        const auto width=pane->output.ActualWidth(),height=pane->output.ActualHeight();if(width<20||height<20)return;
        terminal_ui::ui::TextBlock probe;probe.Text(L"M");probe.FontFamily(terminal_ui::xaml::Media::FontFamily(L"Consolas"));probe.FontSize(14);probe.Measure({1000,1000});
        if(probe.DesiredSize().Width>0)pane->cell_width=probe.DesiredSize().Width;
        const auto columns=static_cast<std::size_t>(std::clamp((width-20)/pane->cell_width,2.0,500.0));
        const auto rows=static_cast<std::size_t>(std::clamp(height/pane->line_height,1.0,200.0));
        if(columns==pane->screen.columns()&&rows==pane->screen.rows())return;
        pane->screen.resize(columns,rows);pane->rendered.clear();pane->output.Items().Clear();pane->dirty=true;
        if(pane->session)pane->session->resize(static_cast<std::int16_t>(columns),static_cast<std::int16_t>(rows));
    }
    static terminal_ui::ui::ScrollViewer scroll_viewer(const terminal_ui::xaml::DependencyObject& root){
        const auto count=terminal_ui::xaml::Media::VisualTreeHelper::GetChildrenCount(root);
        for(int i=0;i<count;++i){const auto child=terminal_ui::xaml::Media::VisualTreeHelper::GetChild(root,i);if(const auto scroll=child.try_as<terminal_ui::ui::ScrollViewer>())return scroll;if(const auto nested=scroll_viewer(child))return nested;}return nullptr;
    }
    void render(const std::shared_ptr<Pane>& pane,bool blink){
        if(!pane->root.IsLoaded())return;
        const auto scroll=scroll_viewer(pane->output);
        const bool follow=!scroll||scroll.VerticalOffset()+scroll.ViewportHeight()>=scroll.ExtentHeight()-pane->line_height*2;
        const auto cursor=pane->screen.cursor();const std::optional<std::size_t> cursor_row=cursor.visible&&blink?std::optional<std::size_t>(pane->screen.scrollback().size()+cursor.row):std::nullopt;
        std::size_t index{};
        const auto append=[&](const TerminalLine& row){
            const bool cursor_changed=(pane->rendered_cursor&&*pane->rendered_cursor==index)||(cursor_row&&*cursor_row==index);
            if(index>=pane->rendered.size()||pane->rendered[index]!=row||cursor_changed){
                auto item=winrt::make<terminal_ui::Row>(row,pane->cell_width,pane->line_height,cursor_row&&*cursor_row==index?std::optional<std::size_t>(cursor.column):std::nullopt,pane->selection);
                if(index<pane->rendered.size()){pane->rendered[index]=row;pane->output.Items().SetAt(static_cast<std::uint32_t>(index),item);}
                else{pane->rendered.push_back(row);pane->output.Items().Append(item);}
            }
            ++index;
        };
        for(const auto& row:pane->screen.scrollback())append(row);for(const auto& row:pane->screen.lines())append(row);
        while(pane->rendered.size()>index){pane->rendered.pop_back();pane->output.Items().RemoveAtEnd();}
        pane->rendered_cursor=cursor_row;pane->blink_visible=blink;pane->dirty=false;
        if(follow&&index)pane->output.ScrollIntoView(pane->output.Items().GetAt(static_cast<std::uint32_t>(index-1)));
    }
    void tick(){
        if(closed_)return;
        const auto deadline=std::chrono::steady_clock::now()+std::chrono::milliseconds(8);bool title_changed{};
        const auto blink=(GetTickCount64()/500)%2==0;
        for(auto& [id,state]:threads_)for(const auto& tab:state.tabs)for(const auto& pane:tab->panes){
            (void)id;
            try{
                if(pane->starting.valid()&&pane->starting.wait_for(std::chrono::milliseconds(0))==std::future_status::ready){
                    pane->session=pane->starting.get();pane->status=winrt::to_string(ui_text(L"Terminal is running."));
                    pane->session->resize(static_cast<std::int16_t>(pane->screen.columns()),static_cast<std::int16_t>(pane->screen.rows()));
                    if(!pane->pending_input.empty()){pane->session->write(pane->pending_input);pane->pending_input.clear();}pane->dirty=true;
                }
                if(pane->session&&pane->pending_bytes<pending_limit/2)for(auto& event:pane->session->take_events()){
                    if(event.kind==TerminalEvent::Kind::output){if(event.bytes.size()>pending_limit-pane->pending_bytes){pane->session->stop();pane->failed=true;pane->status=winrt::to_string(ui_text(L"Terminal display buffer limit reached."));}else{pane->pending_bytes+=event.bytes.size();pane->pending_output.push_back(std::move(event.bytes));}}
                    else if(event.kind==TerminalEvent::Kind::error){pane->failed=true;pane->status=event.bytes;}
                    else if(event.kind==TerminalEvent::Kind::exited){pane->exit_pending=true;pane->exit_code=event.exit_code;}
                }
                const auto old_title=pane->screen.title();
                while(!pane->pending_output.empty()&&std::chrono::steady_clock::now()<deadline){
                    auto& bytes=pane->pending_output.front();const auto count=std::min<std::size_t>(4096,bytes.size()-pane->pending_offset);
                    pane->screen.consume(std::string_view(bytes).substr(pane->pending_offset,count));pane->pending_offset+=count;pane->pending_bytes-=count;pane->dirty=true;
                    if(pane->pending_offset==bytes.size()){pane->pending_output.pop_front();pane->pending_offset=0;}
                }
                title_changed=title_changed||old_title!=pane->screen.title();
                if(pane->exit_pending&&pane->pending_output.empty()&&!pane->exited){pane->screen.finish();pane->exited=true;if(!pane->failed)pane->status=winrt::to_string(ui_text(L"Exited"))+" ("+std::to_string(pane->exit_code)+")";pane->input.IsEnabled(false);pane->dirty=true;}
                pane->status_view.Text(winrt::to_hstring(pane->status));
                const auto active=active_tab();if(visible_&&active&&active->id==tab->id&&(pane->dirty||pane->blink_visible!=blink))render(pane,blink);
            }catch(const std::exception& error){pane->status=error.what();pane->status_view.Text(winrt::to_hstring(pane->status));}
            catch(const winrt::hresult_error& error){pane->status_view.Text(error.message());}
        }
        for(auto at=retired_.begin();at!=retired_.end();){
            const auto& pane=*at;
            if(pane->starting.valid()&&pane->starting.wait_for(std::chrono::milliseconds(0))==std::future_status::ready){try{pane->session=pane->starting.get();pane->session->stop();}catch(...){}}
            if(!pane->starting.valid()&&(!pane->session||pane->session->wait_for_exit(std::chrono::milliseconds(0))))at=retired_.erase(at);else ++at;
        }
        if(title_changed)refresh_tabs();
    }
    void retire(const std::shared_ptr<Pane>& pane){pane->closed=true;if(pane->session)pane->session->stop();retired_.push_back(pane);}
    static void finish_pane(const std::shared_ptr<Pane>& pane)noexcept{
        try{if(pane->starting.valid())pane->session=pane->starting.get();if(pane->session){pane->session->stop();pane->session->shutdown();}}catch(...){}
    }
};
} // namespace coincide
