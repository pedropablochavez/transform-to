// "Transform to" in the Windows 11 context menu (the new one, not "Show more options").
//
// Windows 11 only puts IExplorerCommand handlers from packaged apps in its main menu, so this DLL is registered
// through a sparse MSIX package (see AppxManifest.xml) that points at the install folder. It runs inside a COM
// surrogate (dllhost.exe), never inside explorer.exe.
//
// The DLL knows nothing about formats by itself: the installer writes menu.txt next to it, generated from
// Formats.cs, so the menu always matches what TransformTo.exe can do. When a format is clicked, the selected paths
// are written to a temp file and handed to TransformTo.exe in one go.

#include <windows.h>
#include <shlwapi.h>
#include <shobjidl_core.h>

#include <map>
#include <new>
#include <set>
#include <string>
#include <vector>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "shlwapi.lib")
#pragma comment(lib, "user32.lib")

// Must match the Clsid in AppxManifest.xml.
static const CLSID CLSID_TransformToCommand = {0x74ca12ff, 0x3e89, 0x4ba2, {0xbd, 0xad, 0xcb, 0x31, 0xd3, 0xfb, 0x5a, 0x80}};

static HMODULE g_module;
static LONG g_objects;

namespace {

struct Target {
    std::wstring id;
    std::wstring label;
};

struct Config {
    std::vector<Target> targets;                              // every format, in menu order
    std::map<std::wstring, std::set<std::wstring>> byExtension; // ".png" -> {"jpg", "webp", ...}
};

std::wstring ModuleDir() {
    wchar_t path[MAX_PATH];
    GetModuleFileNameW(g_module, path, MAX_PATH);
    PathRemoveFileSpecW(path);
    return path;
}

std::wstring ExePath() { return ModuleDir() + L"\\TransformTo.exe"; }

std::wstring Widen(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), w.data(), n);
    return w;
}

std::string Narrow(const std::wstring& w) {
    if (w.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), s.data(), n, nullptr, nullptr);
    return s;
}

std::vector<std::wstring> Split(const std::wstring& s, wchar_t sep) {
    std::vector<std::wstring> parts;
    size_t start = 0;
    while (true) {
        size_t end = s.find(sep, start);
        parts.push_back(s.substr(start, end - start));
        if (end == std::wstring::npos) return parts;
        start = end + 1;
    }
}

// menu.txt, UTF-8, one entry per line:
//   T<TAB>id<TAB>label                 a format, in menu order
//   E<TAB>.ext<TAB>id,id,id            formats offered for files with that extension
Config LoadConfig() {
    Config config;
    HANDLE file = CreateFileW((ModuleDir() + L"\\menu.txt").c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return config;
    std::string bytes;
    char buffer[4096];
    DWORD read = 0;
    while (ReadFile(file, buffer, sizeof(buffer), &read, nullptr) && read > 0) bytes.append(buffer, read);
    CloseHandle(file);

    for (auto& raw : Split(Widen(bytes), L'\n')) {
        std::wstring line = raw;
        if (!line.empty() && line.back() == L'\r') line.pop_back();
        auto fields = Split(line, L'\t');
        if (fields.size() != 3) continue;
        if (fields[0] == L"T") {
            config.targets.push_back({fields[1], fields[2]});
        } else if (fields[0] == L"E") {
            auto& ids = config.byExtension[fields[1]];
            for (auto& id : Split(fields[2], L',')) ids.insert(id);
        }
    }
    return config;
}

const Config& GetConfig() {
    static const Config config = LoadConfig();
    return config;
}

std::vector<std::wstring> SelectedPaths(IShellItemArray* items) {
    std::vector<std::wstring> paths;
    DWORD count = 0;
    if (!items || FAILED(items->GetCount(&count))) return paths;
    for (DWORD i = 0; i < count; i++) {
        IShellItem* item = nullptr;
        if (FAILED(items->GetItemAt(i, &item))) continue;
        PWSTR path = nullptr;
        if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path))) {
            paths.push_back(path);
            CoTaskMemFree(path);
        }
        item->Release();
    }
    return paths;
}

std::wstring LowerExtension(const std::wstring& path) {
    std::wstring ext = PathFindExtensionW(path.c_str());
    CharLowerBuffW(ext.data(), (DWORD)ext.size());
    return ext;
}

// Formats at least one of the selected files can be transformed to.
std::set<std::wstring> AvailableIds(const std::vector<std::wstring>& paths) {
    std::set<std::wstring> ids;
    const auto& config = GetConfig();
    for (auto& path : paths) {
        auto it = config.byExtension.find(LowerExtension(path));
        if (it != config.byExtension.end()) ids.insert(it->second.begin(), it->second.end());
    }
    return ids;
}

// Minimal IUnknown for a single interface.
template <typename Interface>
class ComObject : public Interface {
public:
    ComObject() { InterlockedIncrement(&g_objects); }
    virtual ~ComObject() { InterlockedDecrement(&g_objects); }

    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
        if (!ppv) return E_POINTER;
        if (riid == IID_IUnknown || riid == __uuidof(Interface)) {
            *ppv = static_cast<Interface*>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    IFACEMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&refs_); }
    IFACEMETHODIMP_(ULONG) Release() override {
        LONG refs = InterlockedDecrement(&refs_);
        if (refs == 0) delete this;
        return refs;
    }

private:
    LONG refs_ = 1;
};

// One format in the submenu, e.g. "PNG".
class FormatCommand : public ComObject<IExplorerCommand> {
public:
    explicit FormatCommand(Target target) : target_(std::move(target)) {}

    IFACEMETHODIMP GetTitle(IShellItemArray*, LPWSTR* name) override { return SHStrDupW(target_.label.c_str(), name); }
    IFACEMETHODIMP GetIcon(IShellItemArray*, LPWSTR* icon) override { *icon = nullptr; return E_NOTIMPL; }
    IFACEMETHODIMP GetToolTip(IShellItemArray*, LPWSTR* tip) override { *tip = nullptr; return E_NOTIMPL; }
    IFACEMETHODIMP GetCanonicalName(GUID* guid) override { *guid = GUID_NULL; return S_OK; }
    IFACEMETHODIMP GetFlags(EXPCMDFLAGS* flags) override { *flags = ECF_DEFAULT; return S_OK; }
    IFACEMETHODIMP EnumSubCommands(IEnumExplorerCommand** e) override { *e = nullptr; return E_NOTIMPL; }

    IFACEMETHODIMP GetState(IShellItemArray* items, BOOL, EXPCMDSTATE* state) override {
        *state = ECS_ENABLED;
        if (items && AvailableIds(SelectedPaths(items)).count(target_.id) == 0) *state = ECS_HIDDEN;
        return S_OK;
    }

    IFACEMETHODIMP Invoke(IShellItemArray* items, IBindCtx*) override {
        auto paths = SelectedPaths(items);
        if (paths.empty()) return S_OK;

        // Hand the whole selection over in a file: a command line tops out at 32K characters.
        wchar_t tempDir[MAX_PATH], listFile[MAX_PATH];
        GetTempPathW(MAX_PATH, tempDir);
        if (!GetTempFileNameW(tempDir, L"ttl", 0, listFile)) return HRESULT_FROM_WIN32(GetLastError());
        std::string content;
        for (auto& p : paths) content += Narrow(p) + "\n";
        HANDLE file = CreateFileW(listFile, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, nullptr);
        if (file == INVALID_HANDLE_VALUE) return HRESULT_FROM_WIN32(GetLastError());
        DWORD written = 0;
        WriteFile(file, content.data(), (DWORD)content.size(), &written, nullptr);
        CloseHandle(file);

        std::wstring command = L"\"" + ExePath() + L"\" convert --to " + target_.id + L" --list \"" + listFile + L"\"";
        STARTUPINFOW si = {sizeof(si)};
        PROCESS_INFORMATION pi = {};
        AllowSetForegroundWindow(ASFW_ANY); // let the progress window come to the front
        if (!CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi)) {
            DeleteFileW(listFile);
            return HRESULT_FROM_WIN32(GetLastError());
        }
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        return S_OK;
    }

private:
    Target target_;
};

class FormatEnumerator : public ComObject<IEnumExplorerCommand> {
public:
    explicit FormatEnumerator(std::vector<Target> targets) : targets_(std::move(targets)) {}

    IFACEMETHODIMP Next(ULONG count, IExplorerCommand** commands, ULONG* fetched) override {
        ULONG n = 0;
        while (n < count && position_ < targets_.size()) {
            commands[n] = new (std::nothrow) FormatCommand(targets_[position_++]);
            if (!commands[n]) break;
            n++;
        }
        if (fetched) *fetched = n;
        return n == count ? S_OK : S_FALSE;
    }
    IFACEMETHODIMP Skip(ULONG count) override {
        position_ += count;
        return position_ <= targets_.size() ? S_OK : S_FALSE;
    }
    IFACEMETHODIMP Reset() override { position_ = 0; return S_OK; }
    IFACEMETHODIMP Clone(IEnumExplorerCommand** e) override { *e = nullptr; return E_NOTIMPL; }

private:
    std::vector<Target> targets_;
    size_t position_ = 0;
};

// "Transform to" itself: the parent of the submenu.
class TransformToCommand : public ComObject<IExplorerCommand> {
public:
    IFACEMETHODIMP GetTitle(IShellItemArray*, LPWSTR* name) override { return SHStrDupW(L"Transform to", name); }
    IFACEMETHODIMP GetIcon(IShellItemArray*, LPWSTR* icon) override { return SHStrDupW((ExePath() + L",0").c_str(), icon); }
    IFACEMETHODIMP GetToolTip(IShellItemArray*, LPWSTR* tip) override { *tip = nullptr; return E_NOTIMPL; }
    IFACEMETHODIMP GetCanonicalName(GUID* guid) override { *guid = CLSID_TransformToCommand; return S_OK; }
    IFACEMETHODIMP GetFlags(EXPCMDFLAGS* flags) override { *flags = ECF_HASSUBCOMMANDS; return S_OK; }
    IFACEMETHODIMP Invoke(IShellItemArray*, IBindCtx*) override { return E_NOTIMPL; }

    IFACEMETHODIMP GetState(IShellItemArray* items, BOOL, EXPCMDSTATE* state) override {
        // Remember what the selection can become so the submenu only lists those formats.
        available_ = AvailableIds(SelectedPaths(items));
        haveSelection_ = items != nullptr;
        *state = haveSelection_ && available_.empty() ? ECS_HIDDEN : ECS_ENABLED;
        return S_OK;
    }

    IFACEMETHODIMP EnumSubCommands(IEnumExplorerCommand** e) override {
        std::vector<Target> visible;
        for (auto& target : GetConfig().targets)
            if (!haveSelection_ || available_.count(target.id)) visible.push_back(target);
        *e = new (std::nothrow) FormatEnumerator(std::move(visible));
        return *e ? S_OK : E_OUTOFMEMORY;
    }

private:
    std::set<std::wstring> available_;
    bool haveSelection_ = false;
};

class ClassFactory : public ComObject<IClassFactory> {
public:
    IFACEMETHODIMP CreateInstance(IUnknown* outer, REFIID riid, void** ppv) override {
        *ppv = nullptr;
        if (outer) return CLASS_E_NOAGGREGATION;
        auto command = new (std::nothrow) TransformToCommand();
        if (!command) return E_OUTOFMEMORY;
        HRESULT hr = command->QueryInterface(riid, ppv);
        command->Release();
        return hr;
    }
    IFACEMETHODIMP LockServer(BOOL lock) override {
        if (lock) InterlockedIncrement(&g_objects);
        else InterlockedDecrement(&g_objects);
        return S_OK;
    }
};

} // namespace

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_module = module;
        DisableThreadLibraryCalls(module);
    }
    return TRUE;
}

STDAPI DllGetClassObject(REFCLSID clsid, REFIID riid, void** ppv) {
    *ppv = nullptr;
    if (clsid != CLSID_TransformToCommand) return CLASS_E_CLASSNOTAVAILABLE;
    auto factory = new (std::nothrow) ClassFactory();
    if (!factory) return E_OUTOFMEMORY;
    HRESULT hr = factory->QueryInterface(riid, ppv);
    factory->Release();
    return hr;
}

STDAPI DllCanUnloadNow() { return g_objects == 0 ? S_OK : S_FALSE; }

#pragma comment(linker, "/EXPORT:DllGetClassObject,PRIVATE")
#pragma comment(linker, "/EXPORT:DllCanUnloadNow,PRIVATE")
