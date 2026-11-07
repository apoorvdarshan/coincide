# Third-party notices

Coincide ports the design and behavior of T3 Code, and some prompts and wording are adapted from it. The terminal uses SwiftTerm.
Computer Use runs Cua Driver, bundled unmodified in `Coincide.app/Contents/Helpers`.
Dictation with Whisper on the Mac uses WhisperKit. Passkey sign-in checks sites against the Public Suffix List.
Coincide Remote on iPhone and iPad uses RevenueCat's purchases-ios for Coincide Pro and tips.

## T3 Code

https://github.com/pingdotgg/t3code

```
MIT License

Copyright (c) 2026 T3 Tools Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## SwiftTerm

https://github.com/migueldeicaza/SwiftTerm, version 1.99.2, used under the MIT License. Coincide shows this license in
Settings › About (`Coincide/Resources/SwiftTerm-LICENSE.txt`).

```
Copyright (c) 2019-2026 Miguel de Icaza (https://github.com/migueldeicaza)
Copyright (c) 2017-2019, The xterm.js authors (https://github.com/xtermjs/xterm.js)
Copyright (c) 2014-2016, SourceLair Private Company (https://www.sourcelair.com)
Copyright (c) 2012-2013, Christopher Jeffrey (https://github.com/chjj/)
Copyright (c) 2016 Ryan L McIntyre (Powerline Extra Symbols flame silhouette, https://github.com/ryanoasis/powerline-extra-symbols)

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## WhisperKit

https://github.com/argmaxinc/WhisperKit, version 1.1.1 (its WhisperKit and ArgmaxCore libraries), used under the MIT
License. Parts of ArgmaxCore derive from Hugging Face's swift-transformers, under the Apache License 2.0. Coincide
shows both, with WhisperKit's NOTICES file, in Settings › About (`Coincide/Resources/WhisperKit-LICENSE.txt`). No
Whisper model ships with Coincide: models download from huggingface.co/argmaxinc/whisperkit-coreml (MIT) and
OpenAI's tokenizers (Apache 2.0) only when the user asks in Settings › Voice.

```
MIT License

Copyright (c) 2024 argmax, inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## RevenueCat purchases-ios

https://github.com/RevenueCat/purchases-ios (from its SwiftPM mirror, https://github.com/RevenueCat/purchases-ios-spm),
version 5.100.0 (its RevenueCat library), used under the MIT License. Only Coincide Remote links it; the Mac app doesn't.

```
MIT License

Copyright (c) 2024 RevenueCat, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Cua Driver

https://github.com/trycua/cua (`libs/cua-driver`), release cua-driver-rs-v0.38.0, bundled unmodified with Cua AI's own
signature. Coincide shows this license in Settings › About.

```
MIT License

Copyright (c) 2025 Cua AI, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Public Suffix List

https://publicsuffix.org, Mozilla's list of domain suffixes under which separate parties register names, bundled
unmodified as `CoincideKit/Preview/WebAuthn/public_suffix_list.dat` (inside `CoincideKit.framework/Resources`), and
built into the Rust desktop app from the identical `crates/coincide-core/resources/public_suffix_list.dat`, under the
Mozilla Public License 2.0. Its version is on the file's `// VERSION:` line; `scripts/update-public-suffix-list.sh`
replaces it with the current list. Signing in with a Bitwarden passkey uses it to decide which relying party IDs a
site may claim. The file is its own source form; the license is at https://mozilla.org/MPL/2.0/.

```
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.
```

## Bitwarden clients

Signing in with Bitwarden passkeys follows the behavior of Bitwarden's open-source clients
(https://github.com/bitwarden/clients): how passkeys are stored and matched, the authenticator data flags and counter
rule, and the page script's approach. Coincide's code is its own; no Bitwarden code is included.

## Browser and password manager logos

The browser and password manager logos in Settings (`Coincide/Resources/Assets.xcassets`, `Browser-*` and
`PasswordManager*`) are trademarks of their owners. Coincide shows them only to identify the products it imports from
or works with, when the product's own app isn't installed; it isn't affiliated with or endorsed by them. Each is a
64 and 128 px PNG made from the file below, trimmed and centred without other changes. Comet's square App Store icon
was given macOS's rounded corners.

- Google Chrome: [Commons, Google Chrome icon (February 2022)](https://commons.wikimedia.org/wiki/File:Google_Chrome_icon_(February_2022).svg).
  Beta, Dev and Canary: google.com/chrome
  ([Beta](https://www.google.com/chrome/static/images/beta/chrome-beta-logo.svg),
  [Dev](https://www.google.com/chrome/static/images/dev/chrome-dev-logo.svg),
  [Canary](https://www.google.com/chrome/static/images/canary/chrome-canary-logo.svg)).
- Chromium: [Commons, Chromium Logo](https://commons.wikimedia.org/wiki/File:Chromium_Logo.svg).
- Brave: [Commons, Brave lion icon](https://commons.wikimedia.org/wiki/File:Brave_lion_icon.svg) (MPL 2.0). Beta and
  Nightly: [brave-core](https://github.com/brave/brave-core/tree/master/app/theme/brave) `product_logo_128_beta.png`
  and `product_logo_128_nightly.png` (MPL 2.0).
- Microsoft Edge, Beta, Dev and Canary (MIT, on Commons):
  [Edge](https://commons.wikimedia.org/wiki/File:Microsoft_Edge_logo_(2019).svg),
  [Beta](https://commons.wikimedia.org/wiki/File:Microsoft_Edge_Beta_Icon_(2019).svg),
  [Dev](https://commons.wikimedia.org/wiki/File:Microsoft_Edge_Dev_Icon_(2019).svg),
  [Canary](https://commons.wikimedia.org/wiki/File:Microsoft_Edge_Canary_Logo_(2019).svg).
- Arc: [Commons, Arc (browser) logo](https://commons.wikimedia.org/wiki/File:Arc_(browser)_logo.svg).
- Dia: [diabrowser.com/favicon.svg](https://www.diabrowser.com/favicon.svg).
- Vivaldi: [Commons, Vivaldi web browser logo](https://commons.wikimedia.org/wiki/File:Vivaldi_web_browser_logo.svg) (CC BY 4.0).
- Opera and Opera GX: [Commons, Opera 2015 icon](https://commons.wikimedia.org/wiki/File:Opera_2015_icon.svg),
  [Commons, Opera GX Icon](https://commons.wikimedia.org/wiki/File:Opera_GX_Icon.svg).
- Yandex Browser: [Commons, Yandex Browser icon](https://commons.wikimedia.org/wiki/File:Yandex_Browser_icon.svg).
- Perplexity Comet: its [App Store icon](https://apps.apple.com/app/id6748622471), from Apple's iTunes Search API.
- Sidekick: meetsidekick.com's site icon, through the
  [Internet Archive](http://web.archive.org/web/20240101233405/https://www.meetsidekick.com/) (the site now forwards to Comet).
- Thorium: [Thorium's repository](https://github.com/Alex313031/thorium/blob/main/logos/NEW/product_logo.svg).
- Helium: [helium.computer/favicon.png](https://helium.computer/favicon.png).
- Firefox: [Commons, Firefox logo, 2019](https://commons.wikimedia.org/wiki/File:Firefox_logo,_2019.svg) (MPL 2.0).
- LibreWolf: [librewolf.net/icon.svg](https://librewolf.net/icon.svg).
- Zen: [zen-browser.app/favicon.svg](https://zen-browser.app/favicon.svg).
- Floorp: [floorp.app/icon.svg](https://floorp.app/icon.svg).
- Waterfox: [waterfox.net/favicons/favicon.svg](https://www.waterfox.net/favicons/favicon.svg).
- Safari and Safari Technology Preview: [developer.apple.com/safari](https://developer.apple.com/safari/)
  (`safari-128x128_2x.png`, `safari-technology-preview-128x128_2x.png`).
- Orion: [orionbrowser.com](https://orionbrowser.com/android-chrome-192x192.png).
- DuckDuckGo: [duckduckgo.com](https://duckduckgo.com/static-assets/favicons/DDG-icon_256x256.png).
- 1Password: [1password.com](https://1password.com/favicon/icon-v2.svg), with
  [icon-v2-light.svg](https://1password.com/favicon/icon-v2-light.svg) in Dark Mode.
- Bitwarden: [bitwarden.com](https://bitwarden.com/icons/icon-512x512.png).
