<p align="center"><img src="assets/icon-1024.png" width="96" alt=""></p>

<h1 align="center">Transform To</h1>

<p align="center">Right-click any file → <b>Transform to</b> → pick a format. Works with one file or hundreds at once.<br>
<a href="#español">Leer en español</a></p>

---

## What it does

- **Images**: JPG, PNG, WEBP, GIF, BMP, TIFF, ICO, AVIF, HEIC (iPhone photos), SVG → JPG, PNG, WEBP, GIF, BMP, TIFF, ICO, AVIF, PDF
- **Many images → one PDF**: "PDF (all in one file)" merges the whole selection into a single PDF
- **Word**: DOCX, DOC, ODT, RTF → PDF, DOCX, DOC, ODT, RTF, TXT, HTML
- **Excel**: XLSX, XLS, ODS, CSV → PDF, XLSX, XLS, ODS, CSV
- **PowerPoint**: PPTX, PPT, ODP → PDF, PPTX, PPT, ODP
- **Batch**: select as many files as you like; they are converted together with one progress window
- Converted files are saved next to the originals (`photo.jpg` → `photo.png`). Nothing is overwritten: if the name is taken you get `photo (1).png`.
- The menu only lists formats that make sense: a `.png` never offers "PNG".

## Windows

1. Download `TransformTo-windows-x64.zip` from [Releases](../../releases) and unzip it.
2. Double-click `TransformTo.exe` and press **Install**. No admin rights needed.
3. Right-click a file → **Transform to**.

On Windows 11 the item is under **Show more options** (or hold **Shift** while right-clicking).

Uninstall from *Settings → Apps → Installed apps → Transform To*, or run `TransformTo.exe` again and press **Uninstall**.

Documents (Word/Excel/PowerPoint) are converted with **Microsoft Office** if it's installed, otherwise with **[LibreOffice](https://www.libreoffice.org)** (free). Images need nothing extra.

Windows SmartScreen may warn the first time because the exe isn't code-signed: click *More info → Run anyway*.

<details><summary>Command line</summary>

```
TransformTo.exe convert --to png  photo1.jpg photo2.jpg
TransformTo.exe convert --to pdf  --no-ui report.docx     # no window, prints results
TransformTo.exe install | uninstall [--quiet]
```
</details>

## macOS

1. Download `TransformTo-mac.zip` from [Releases](../../releases), unzip it and drag **Transform To.app** into **Applications**.
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

**macOS** — needs Xcode (free on the App Store) or just the Command Line Tools (`xcode-select --install`). No paid Apple Developer account required:

```
bash mac/build-app.sh
```

Every push builds both versions on GitHub Actions; pushing a `v*` tag publishes a release with both zips.

## How it works

- **Windows**: the installer registers a cascading "Transform to" menu under `HKEY_CURRENT_USER\Software\Classes\SystemFileAssociations\.<ext>\shell`. Explorer starts one process per selected file; the first one becomes a collector and the rest hand it their file through a named pipe, so the whole selection is converted as one batch. Images use [Magick.NET](https://github.com/dlemstra/Magick.NET) (ImageMagick); documents use Office automation or LibreOffice headless.
- **macOS**: a regular app that registers a Finder service (`NSServices`); images go through ImageIO, documents through the macOS text system or LibreOffice.

## License

[MIT](LICENSE). Uses Magick.NET / ImageMagick (Apache 2.0).

---

## Español

**Transform To** agrega la opción **"Transform to"** al menú del clic derecho: eliges un archivo (o muchos), eliges el formato y listo.

### Qué convierte

- **Imágenes**: JPG, PNG, WEBP, GIF, BMP, TIFF, ICO, AVIF, HEIC (fotos de iPhone), SVG → JPG, PNG, WEBP, GIF, BMP, TIFF, ICO, AVIF, PDF
- **Varias imágenes → un solo PDF** con "PDF (all in one file)"
- **Word**: DOCX, DOC, ODT, RTF → PDF, DOCX, DOC, ODT, RTF, TXT, HTML
- **Excel**: XLSX, XLS, ODS, CSV → PDF, XLSX, XLS, ODS, CSV
- **PowerPoint**: PPTX, PPT, ODP → PDF, PPTX, PPT, ODP
- **Por lotes**: selecciona todos los archivos que quieras y se convierten juntos.
- El archivo nuevo queda junto al original y nunca se sobrescribe nada.

### Windows

1. Descarga `TransformTo-windows-x64.zip` desde [Releases](../../releases) y descomprímelo.
2. Abre `TransformTo.exe` y pulsa **Install** (no necesita permisos de administrador).
3. Clic derecho en un archivo → **Transform to**. En Windows 11 está en **Mostrar más opciones** (o Shift + clic derecho).

Los documentos se convierten con **Microsoft Office** si lo tienes; si no, con **LibreOffice** (gratis).

### macOS

1. Descarga `TransformTo-mac.zip`, descomprímelo y arrastra **Transform To.app** a **Aplicaciones**.
2. Ábrela una vez. Como no está notarizada por Apple, macOS la bloquea la primera vez: ve a *Ajustes del Sistema → Privacidad y seguridad* y pulsa **Abrir igualmente**.
3. En Finder selecciona archivos → clic derecho → **Acciones rápidas** (o **Servicios**) → **Transform to…**

Compilarla en un Mac es **gratis**: solo necesitas Xcode (gratis en la App Store) y correr `bash mac/build-app.sh`. La cuenta de Apple Developer de pago (99 USD/año) solo hace falta para notarizar la app y evitar el aviso de seguridad, o para publicarla en la App Store.
