#pragma once
#include "../Core/Markdown.h"
#include "NativeStrings.h"
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Documents.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Windows.ApplicationModel.DataTransfer.h>
#include <winrt/Windows.System.h>
#include <winrt/Windows.UI.Text.h>
#include <functional>

namespace coincide {
namespace native_markdown {
namespace xaml = winrt::Microsoft::UI::Xaml;
namespace ui = xaml::Controls;
namespace docs = xaml::Documents;
using Navigator = std::function<void(std::string)>;
using Preview = std::function<void(std::string,bool)>;
inline void identify(const xaml::DependencyObject& value, const wchar_t* id) {xaml::Automation::AutomationProperties::SetAutomationId(value, id);}
inline void navigate(std::string target, const Navigator& action) {
    if (!markdown::safe_link(target)) return;
    if (action) action(std::move(target));
    else (void)winrt::Windows::System::Launcher::LaunchUriAsync(winrt::Windows::Foundation::Uri(winrt::to_hstring(target)));
}
inline void append(const docs::Paragraph& paragraph, const std::vector<markdown::Span>& spans, const Navigator& action) {
    for (const auto& span : spans) {
        docs::Run run; run.Text(winrt::to_hstring(span.text));
        if (span.style & markdown::bold) run.FontWeight(winrt::Windows::UI::Text::FontWeights::SemiBold());
        if (span.style & markdown::italic) run.FontStyle(winrt::Windows::UI::Text::FontStyle::Italic);
        if (span.style & markdown::code) run.FontFamily(xaml::Media::FontFamily(L"Consolas"));
        if (span.style & markdown::strike) run.TextDecorations(winrt::Windows::UI::Text::TextDecorations::Strikethrough);
        if (!span.link.empty()) {
            docs::Hyperlink link; identify(link, L"TranscriptLink");
            xaml::Automation::AutomationProperties::SetName(link, winrt::to_hstring(span.text));
            link.Inlines().Append(run);
            link.Click([target = span.link, action](const auto&, const auto&) {navigate(target, action);});
            paragraph.Inlines().Append(link);
        } else paragraph.Inlines().Append(run);
    }
}
inline ui::RichTextBlock text(const std::vector<markdown::Span>& spans, const Navigator& action) {
    ui::RichTextBlock block; block.IsTextSelectionEnabled(true); block.TextWrapping(xaml::TextWrapping::Wrap);
    docs::Paragraph paragraph; append(paragraph, spans, action); block.Blocks().Append(paragraph); return block;
}
inline ui::StackPanel render(std::string_view source, const winrt::hstring& copy_label, Navigator action = {}, Preview preview = {}) {
    ui::StackPanel content; content.Spacing(8); content.Margin({12, 8, 12, 8});
    for (const auto& block : markdown::parse(source)) {
        if (block.kind == markdown::Block::fenced_code) {
            ui::StackPanel code; code.Spacing(6); code.Padding({10, 8, 10, 8});
            ui::StackPanel toolbar; toolbar.Orientation(ui::Orientation::Horizontal); toolbar.Spacing(12);
            if (!block.language.empty()) {ui::TextBlock language; language.Text(winrt::to_hstring(block.language)); language.Opacity(0.7); toolbar.Children().Append(language);}
            ui::Button copy; copy.Content(winrt::box_value(copy_label)); identify(copy, L"CopyCode");
            copy.Click([value = block.text](const auto&, const auto&) {
                winrt::Windows::ApplicationModel::DataTransfer::DataPackage data;
                data.SetText(winrt::to_hstring(value)); winrt::Windows::ApplicationModel::DataTransfer::Clipboard::SetContent(data);
            });
            toolbar.Children().Append(copy);
            if(preview&&(block.language=="coincide-html"||block.language=="coincide-svg")){
                ui::Button show;show.Content(winrt::box_value(ui_text(L"Preview")));identify(show,L"PreviewOutput");
                show.Click([value=block.text,svg=block.language=="coincide-svg",preview](const auto&,const auto&){preview(value,svg);});toolbar.Children().Append(show);
            }
            code.Children().Append(toolbar);
            ui::TextBlock code_text; code_text.Text(winrt::to_hstring(block.text)); code_text.IsTextSelectionEnabled(true);
            code_text.FontFamily(xaml::Media::FontFamily(L"Consolas")); code_text.TextWrapping(xaml::TextWrapping::Wrap); identify(code_text, L"CodeBlockText");
            code.Children().Append(code_text);
            ui::Border border; border.BorderThickness({1, 1, 1, 1}); border.CornerRadius({6, 6, 6, 6}); border.Child(code);
            content.Children().Append(border); continue;
        }
        if (block.kind == markdown::Block::rule) {
            ui::Border separator; separator.BorderThickness({0, 1, 0, 0}); separator.Opacity(0.4); separator.Margin({0, 8, 0, 8});
            content.Children().Append(separator); continue;
        }
        if (block.kind == markdown::Block::image) {
            // Untrusted Markdown never fetches a remote image automatically. Opening it is an explicit action.
            ui::HyperlinkButton link; link.Content(winrt::box_value(winrt::to_hstring(block.text.empty() ? block.marker : block.text)));
            identify(link, L"TranscriptImageLink"); link.Click([target=block.marker, action](const auto&, const auto&) {navigate(target, action);});
            content.Children().Append(link); continue;
        }
        if (block.kind == markdown::Block::table) {
            ui::Grid table; table.ColumnSpacing(12); table.RowSpacing(8); identify(table, L"MarkdownTable");
            for (std::size_t column = 0; column < block.rows.front().size(); ++column) {ui::ColumnDefinition definition; definition.Width({1, xaml::GridUnitType::Star}); table.ColumnDefinitions().Append(definition);}
            for (std::size_t row = 0; row < block.rows.size(); ++row) {
                ui::RowDefinition definition; definition.Height({1, xaml::GridUnitType::Auto}); table.RowDefinitions().Append(definition);
                for (std::size_t column = 0; column < block.rows[row].size(); ++column) {
                    auto cell = text(markdown::inline_text(block.rows[row][column], row == 0 ? markdown::bold : markdown::normal), action);
                    ui::Grid::SetRow(cell, static_cast<int32_t>(row)); ui::Grid::SetColumn(cell, static_cast<int32_t>(column)); table.Children().Append(cell);
                }
            }
            content.Children().Append(table); continue;
        }
        auto paragraph = text(block.spans, action);
        if (block.kind == markdown::Block::heading) {paragraph.FontSize(std::max(15.0, 27.0 - block.level * 2)); paragraph.FontWeight(winrt::Windows::UI::Text::FontWeights::SemiBold());}
        if (block.kind == markdown::Block::bullet) {
            ui::Grid row; ui::ColumnDefinition prefix; prefix.Width({32, xaml::GridUnitType::Pixel}); row.ColumnDefinitions().Append(prefix); row.ColumnDefinitions().Append(ui::ColumnDefinition{});
            ui::TextBlock marker; marker.Text(winrt::to_hstring(block.marker)); row.Children().Append(marker);
            ui::Grid::SetColumn(paragraph, 1); row.Children().Append(paragraph); content.Children().Append(row);
        } else if (block.kind == markdown::Block::quote) {
            ui::Border quote; quote.Padding({12, 0, 0, 0}); quote.BorderThickness({3, 0, 0, 0}); quote.Opacity(0.85); quote.Child(paragraph); content.Children().Append(quote);
        } else content.Children().Append(paragraph);
    }
    return content;
}
} // namespace native_markdown
} // namespace coincide
