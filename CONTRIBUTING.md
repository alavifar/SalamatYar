# Contributing to SalamatYar

Thank you for helping. Issues and pull requests are welcome in English or Persian.

## Files

| File | Purpose |
| --- | --- |
| `SalamatYar.ps1` | The whole app: timers, WPF interface, sound synthesis |
| `lang.json` | All interface text, one entry per key, five languages in a fixed order |
| `Run.cmd` | Starts the app without a console window |
| `tools/audit-lang.ps1` | Checks that `lang.json` is complete and consistent |
| `launcher/Launcher.cs` | Source of `SalamatYar.exe`, a small launcher that starts the script without a console window |
| `tools/build.ps1` | Compiles the launcher and builds `dist/SalamatYar.zip`, the package users download |

After changing the app, run `tools\build.ps1` so that `dist/SalamatYar.zip` matches the source.

`SalamatYar.ps1` must stay saved as **UTF-8 with BOM**. Windows PowerShell 5.1 reads a BOM-less file in the system code page and breaks the non-Latin text.

## Fix or improve a translation

Edit the text in `lang.json`. Each key holds an array in the order given by `_order` (`fa`, `en`, `ar`, `ru`, `zh`). Then run the audit:

```
powershell -NoProfile -ExecutionPolicy Bypass -File tools\audit-lang.ps1 -Dir .
```

Rules the audit enforces:

- every key has one non-empty text per language;
- placeholders such as `{0}` match across languages;
- the characters `&`, `<`, `>` and `"` are not used (texts are inserted into XAML);
- every key used by the app exists, and no key is unused.

The Arabic, Russian and Chinese texts were written by a non-native speaker. Corrections from native speakers are especially welcome.

## Add a language

1. Add the language code to `_order` in `lang.json` and append its text to every key.
2. In `SalamatYar.ps1`, add the code and its native name to `$LangNames`, add a button to the language popup, and include the code in `$IsRtl` if it is written right to left.
3. Add the code to the checks in `tools/audit-lang.ps1`.

## Test the interface

The app has a built-in self-test that opens every page, takes screenshots into a folder and exits. It uses a temporary data folder, so your own settings are not touched.

```
powershell -NoProfile -ExecutionPolicy Bypass -File SalamatYar.ps1 -SelfTest -LangTest -Lang ru -TestDir C:\Temp\salamatyar-test
```

Look at the screenshots before opening a pull request, especially for long texts that may overflow.

## Cross-platform edition

The folder `app/` holds a preview of SalamatYar for Windows, macOS and Linux, built with Tauri. It reads the same `lang.json`, so a translation fix reaches both editions. See [app/README.md](app/README.md) for how to build, test and preview it. Testing on macOS and Linux is the most useful help right now.

## Health content

Changes to the default timings or to the health guide need a source from a recognised body (for example AOA, AAO, OSHA, HSE or WHO). Please cite it in the pull request.
