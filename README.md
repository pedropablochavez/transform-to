<p align="center"><img src="assets/icon-1024.png" width="96" alt=""></p>

<h1 align="center">Transform To</h1>

<p align="center">Right-click any file → <b>Transform to</b> → pick a format. Works with one file or hundreds at once.<br>
<a href="#español">Leer en español</a></p>

<p align="center">
  <a href="https://github.com/pedropablochavez/transform-to/releases/latest/download/TransformTo.exe"><img src="https://img.shields.io/badge/Download_for_Windows-TransformTo.exe-2ea44f?style=for-the-badge" alt="Download for Windows"></a>
  <a href="https://github.com/pedropablochavez/transform-to/releases/latest/download/TransformTo-mac.zip"><img src="https://img.shields.io/badge/Download_for_Mac-.zip-555555?style=for-the-badge" alt="Download for Mac"></a>
</p>

---

## What it does

- **Images**: JPG, PNG, WEBP, GIF, BMP, TIFF, ICO, AVIF, HEIC (iPhone photos), NEF (Nikon RAW), SVG → JPG, PNG, WEBP, GIF, BMP, TIFF, ICO, AVIF, PDF
- **Many images → one PDF**: "PDF (all in one file)" merges the whole selection into a single PDF
- **Word**: DOCX, DOC, ODT, RTF → PDF, DOCX, DOC, ODT, RTF, TXT, HTML
- **Excel**: XLSX, XLS, ODS, CSV → PDF, XLSX, XLS, ODS, CSV
- **PowerPoint**: PPTX, PPT, ODP → PDF, PPTX, PPT, ODP
- **Batch**: select as many files as you like; they are converted together with one progress window
- Converted files are saved next to the originals (`photo.jpg` → `photo.png`). Nothing is overwritten: if the name is taken you get `photo (1).png`.
- The menu only lists formats that make sense: a `.png` never offers "PNG".

## Windows

1. **[Download TransformTo.exe](https://github.com/pedropablochavez/transform-to/releases/latest/download/TransformTo.exe)**. Nothing else to install.
2. Double-click it. Windows SmartScreen may warn the first time because the exe isn't code-signed: click *More info → Run anyway*.
3. Press **Install**.
4. Right-click a file → **Transform to**.

On **Windows 11** "Transform to" goes straight into the main right-click menu. To get there, Windows requires the app to be a
signed package, so the first install shows **one admin (UAC) prompt** to trust the project's self-signed certificate
(`CN=TransformTo`, added to the computer's *Trusted People* store). If you decline, it still works under **Show more options**.
On Windows 10 it's always in the classic menu and needs no admin rights.

Uninstall from *Settings → Apps → Installed apps → Transform To*, or run `TransformTo.exe` again and press **Uninstall**.

Documents (Word/Excel/PowerPoint) are converted with **Microsoft Office** if it's installed, otherwise with **[LibreOffice](https://www.libreoffice.org)** (free). Images need nothing extra.

<details><summary>Command line</summary>

```
TransformTo.exe convert --to png  photo1.jpg photo2.jpg
TransformTo.exe convert --to pdf  --no-ui report.docx     # no window, prints results
TransformTo.exe install | uninstall [--quiet]
```
</details>

## macOS

1. **[Download TransformTo-mac.zip](https://github.com/pedropablochavez/transform-to/releases/latest/download/TransformTo-mac.zip)**, unzip it and drag **Transform To.app** into **Applications**.
2. Open it once. Because the app isn't notarized by Apple, macOS will block it the first time:
   go to *System Settings → Privacy & Security* and click **Open Anyway** (or run `xattr -dr com.apple.quarantine "/Applications/Transform To.app"`).
3. In Finder select files, right-click → **Quick Actions** (or **Services**) → **Transform to…** and choose the format.
   If it's not there, enable it in *System Settings → Keyboard → Keyboard Shortcuts → Services → Files and Folders*.

On Mac, images use the system's ImageIO (outputs: JPG, PNG, HEIC, GIF, BMP, TIFF, ICO, PDF; WEBP/AVIF can be read but not written). Word/RTF/ODT text documents work out of the box; spreadsheets and presentations need [LibreOffice](https://www.libreoffice.org).

## Building from source

**Windows** — needs the [.NET 10 SDK](https://dotnet.microsoft.com/download):

```
dotnet publish windows/TransformTo -c Release -o windows/publish
```

That gives the classic menu. For the Windows 11 main menu, first build the shell extension (needs Visual Studio Build Tools
with the C++ workload, and the signing `.pfx`, which is not in the repo):

```
pwsh windows/ShellExtension/build.ps1 -Pfx path\to\TransformTo.pfx -Password ...
```

CI does this automatically when the `SIGNING_PFX_BASE64` and `SIGNING_PASSWORD` repository secrets are set.

**macOS** — needs Xcode (free on the App Store) or just the Command Line Tools (`xcode-select --install`). No paid Apple Developer account required:

```
bash mac/build-app.sh
```

Every push builds both versions on GitHub Actions; pushing a `v*` tag publishes a release with `TransformTo.exe` and `TransformTo-mac.zip`.

## How it works

- **Windows 11**: a small C++ `IExplorerCommand` handler (`windows/ShellExtension`) registered through a sparse MSIX package whose files live in the install folder. Explorer passes it the whole selection, which it hands to `TransformTo.exe` in one go.
- **Windows 10 / fallback**: the installer registers a cascading "Transform to" menu under `HKEY_CURRENT_USER\Software\Classes\SystemFileAssociations\.<ext>\shell`. Explorer starts one process per selected file; the first one becomes a collector and the rest hand it their file through a named pipe, so the whole selection is converted as one batch. Images use [Magick.NET](https://github.com/dlemstra/Magick.NET) (ImageMagick); documents use Office automation or LibreOffice headless.
- **macOS**: a regular app that registers a Finder service (`NSServices`); images go through ImageIO, documents through the macOS text system or LibreOffice.

## License

[MIT](LICENSE). Uses Magick.NET / ImageMagick (Apache 2.0).

---

## Español

**Transform To** agrega la opción **"Transform to"** al menú del clic derecho: eliges un archivo (o muchos), eliges el formato y listo.

### Qué convierte

- **Imágenes**: JPG, PNG, WEBP, GIF, BMP, TIFF, ICO, AVIF, HEIC (fotos de iPhone), NEF (RAW de Nikon), SVG → JPG, PNG, WEBP, GIF, BMP, TIFF, ICO, AVIF, PDF
- **Varias imágenes → un solo PDF** con "PDF (all in one file)"
- **Word**: DOCX, DOC, ODT, RTF → PDF, DOCX, DOC, ODT, RTF, TXT, HTML
- **Excel**: XLSX, XLS, ODS, CSV → PDF, XLSX, XLS, ODS, CSV
- **PowerPoint**: PPTX, PPT, ODP → PDF, PPTX, PPT, ODP
- **Por lotes**: selecciona todos los archivos que quieras y se convierten juntos.
- El archivo nuevo queda junto al original y nunca se sobrescribe nada.

### Windows

1. **[Descarga TransformTo.exe](https://github.com/pedropablochavez/transform-to/releases/latest/download/TransformTo.exe)**. No hace falta instalar nada más.
2. Ábrelo. Windows SmartScreen puede avisar la primera vez porque el exe no tiene firma de código: pulsa *Más información → Ejecutar de todas formas*.
3. Pulsa **Install** (no necesita permisos de administrador).
4. Clic derecho en un archivo → **Transform to**. En Windows 11 aparece directo en el menú principal: la primera vez Windows pide permiso de administrador una sola vez para confiar en el certificado de la app. Si lo rechazas, igual funciona desde **Mostrar más opciones**.

Los documentos se convierten con **Microsoft Office** si lo tienes; si no, con **LibreOffice** (gratis).

### macOS

1. **[Descarga TransformTo-mac.zip](https://github.com/pedropablochavez/transform-to/releases/latest/download/TransformTo-mac.zip)**, descomprímelo y arrastra **Transform To.app** a **Aplicaciones**.
2. Ábrela una vez. Como no está notarizada por Apple, macOS la bloquea la primera vez: ve a *Ajustes del Sistema → Privacidad y seguridad* y pulsa **Abrir igualmente**.
3. En Finder selecciona archivos → clic derecho → **Acciones rápidas** (o **Servicios**) → **Transform to…**

Compilarla en un Mac es **gratis**: solo necesitas Xcode (gratis en la App Store) y correr `bash mac/build-app.sh`. La cuenta de Apple Developer de pago (99 USD/año) solo hace falta para notarizar la app y evitar el aviso de seguridad, o para publicarla en la App Store.
