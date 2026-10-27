# Coincide

A native macOS app for driving the coding agents you already pay for — Claude Code, Codex, Cursor, Grok Build, OpenCode, Pi and Antigravity — from one window, with one model picker, and the ability to switch agents in the middle of a thread.

Coincide is an AppKit port of [T3 Code](https://github.com/pingdotgg/t3code) (MIT). It runs each agent's own CLI with your existing login; it never sells or proxies tokens.

> Work in progress.

## Build

Requires macOS 26 or later and Xcode 26 or later.

```sh
brew install xcodegen
xcodegen generate
open Coincide.xcodeproj
```
