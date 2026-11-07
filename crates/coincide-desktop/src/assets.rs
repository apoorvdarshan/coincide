//! Native UI icon source, embedded in both debug and release executables.
//!
//! This is the complete default component icon set from pinned gpui-kit-assets
//! 0.9.0 (`default-icons.txt`), rather than RustEmbed's debug filesystem loader.
//! The official macro borrows include_bytes! data from that pinned dependency.
//! Parent hook: register this module and call
//! `application.with_assets(assets::CoincideAssets)` before `application.run(...)`.

use gpui_kit::assets::icon_assets;

icon_assets!(
    pub(crate) CoincideAssets,
    [
        ALargeSmall,
        Archive,
        Boxes,
        ChartColumn,
        Keyboard,
        Monitor,
        ArrowDown,
        ArrowLeft,
        ArrowRight,
        ArrowUp,
        Asterisk,
        AtSign,
        Brain,
        CornerUpRight,
        Hammer,
        ListPlus,
        Lock,
        LockOpen,
        Paperclip,
        PencilRuler,
        Zap,
        Ban,
        BatteryCharging,
        BatteryFull,
        BatteryLow,
        BatteryMedium,
        BatteryWarning,
        Battery,
        Bell,
        BookOpen,
        Bot,
        Building2,
        Calendar,
        Camera,
        CaseSensitive,
        ChartPie,
        ChartNoAxesColumn,
        CircleArrowUp,
        MessagesSquare,
        SquarePen,
        SquareArrowOutUpRight,
        Clock,
        FolderPlus,
        Check,
        ChevronDown,
        ChevronLeft,
        ChevronRight,
        ChevronUp,
        ChevronsUpDown,
        CircleAlert,
        CircleCheck,
        CircleUser,
        CircleX,
        Close,
        Copy,
        Cpu,
        Dash,
        Delete,
        EllipsisVertical,
        Ellipsis,
        ExternalLink,
        EyeOff,
        Eye,
        FileText,
        File,
        FolderClosed,
        FolderOpen,
        Folder,
        Frame,
        GalleryVerticalEnd,
        GitBranch,
        Github,
        Globe,
        HardDrive,
        HeartOff,
        Heart,
        Inbox,
        Info,
        Inspector,
        LayoutDashboard,
        LoaderCircle,
        Loader,
        Map,
        Maximize,
        MemoryStick,
        Menu,
        Mic,
        Minimize,
        Minus,
        Moon,
        Network,
        Palette,
        PanelBottomOpen,
        PanelBottom,
        PanelLeftClose,
        PanelLeftOpen,
        PanelLeft,
        PanelRightClose,
        PanelRightOpen,
        PanelRight,
        Pause,
        Pin,
        Play,
        Plus,
        Redo2,
        Redo,
        RefreshCw,
        Replace,
        ResizeCorner,
        RotateCw,
        Search,
        Settings2,
        Settings,
        ShieldAlert,
        SortAscending,
        SortDescending,
        SkipForward,
        SquareTerminal,
        Square,
        StarFill,
        StarOff,
        Star,
        Sun,
        ThumbsDown,
        ThumbsUp,
        TriangleAlert,
        Undo2,
        Undo,
        User,
        WindowClose,
        WindowMaximize,
        WindowMinimize,
        WindowRestore,
    ]
);

#[cfg(test)]
mod tests {
    use super::CoincideAssets;
    use gpui_kit::AssetSource;
    use std::borrow::Cow;

    #[test]
    fn component_icons_are_borrowed_embedded_svg_bytes() {
        let source = CoincideAssets;
        // Input, clear/search, disclosure, menus and loading controls rely on these.
        for path in [
            "icons/eye.svg",
            "icons/eye-off.svg",
            "icons/close.svg",
            "icons/search.svg",
            "icons/chevron-down.svg",
            "icons/chevron-right.svg",
            "icons/check.svg",
            "icons/ellipsis.svg",
            "icons/loader-circle.svg",
            // Composer actions already reference these non-default icons.
            "icons/camera.svg",
            "icons/brain.svg",
            "icons/zap.svg",
            "icons/lock.svg",
            "icons/lock-open.svg",
            "icons/hammer.svg",
            "icons/pencil-ruler.svg",
            "icons/paperclip.svg",
            "icons/at-sign.svg",
            "icons/list-plus.svg",
            "icons/corner-up-right.svg",
            "icons/skip-forward.svg",
            "icons/arrow-up.svg",
            "icons/square.svg",
            // Sidebar thread rows: pinned and waiting-for-approval marks.
            "icons/pin.svg",
            "icons/shield-alert.svg",
        ] {
            let bytes = source.load(path).unwrap().expect(path);
            assert!(matches!(&bytes, Cow::Borrowed(_)), "{path}");
            assert!(bytes.windows(4).any(|part| part == b"<svg"), "{path}");
            assert!(
                source
                    .list("icons/")
                    .unwrap()
                    .iter()
                    .any(|listed| listed.as_ref() == path)
            );
        }
    }

    #[test]
    fn unrelated_paths_are_not_resolved_as_icons() {
        let source = CoincideAssets;
        for path in [
            "",
            "../icons/check.svg",
            "icons/not-an-icon.svg",
            "secrets.json",
        ] {
            assert!(source.load(path).unwrap().is_none());
        }
        assert!(source.list("unrelated/").unwrap().is_empty());
    }
}
