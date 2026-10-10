// d3dprobe: creates a D3D11 (or D3D12) device and prints what it got, so a backend can be
// checked without a game. Build with tools/d3dprobe/build.sh; run through `neutron run`.
//
//   d3dprobe.exe        D3D11 device + adapter info
//   d3dprobe.exe 12     D3D12 device
//   d3dprobe.exe 9      D3D9 device (HAL, hidden window) + adapter info
//   d3dprobe.exe 8      D3D8 device (HAL, hidden window) + adapter info (d3dprobe8.c)
//   d3dprobe.exe shared D3D11 shared texture: GetSharedHandle on one device, open on another
//                       (what Media Foundation video playback in Unity relies on)
//   d3dprobe.exe timestamp  D3D11 timestamp + disjoint queries around a clear (what Unreal's GPU
//                       timing and its timestamp calibration rely on)
//   d3dprobe.exe calibrate  Unreal Engine 5's D3D11 timestamp calibration, step by step: once an
//                       event query issued after them has signalled, the timestamp and disjoint
//                       queries must already have results (Windows completes queries in order)
//   d3dprobe.exe crossproc  creates a window, then a second d3dprobe process presents red into it
//                       through a D3D11 swap chain (what Chromium's GPU process does; Steam)
//   d3dprobe.exe crossproc inset  the same into a 300x200 child window at (80,60) of a gray
//                       window, to check where the other process's frames land
//   d3dprobe.exe queryorder  polls timestamp and disjoint queries without waiting, frame by frame,
//                       and counts timestamps that were ready before their disjoint query
//
// Exit code 0 means the device was created.
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <stdio.h>
#include <d3d11.h>
#include <d3d12.h>
#include <d3d9.h>
#include <dxgi.h>

static void print_module(const char *name) {
    HMODULE module = GetModuleHandleA(name);
    char path[MAX_PATH] = "(not loaded)";
    if (module) GetModuleFileNameA(module, path, sizeof(path));
    printf("  %-14s %s\n", name, path);
}

static void print_adapter(IDXGIAdapter *adapter) {
    DXGI_ADAPTER_DESC desc;
    if (SUCCEEDED(IDXGIAdapter_GetDesc(adapter, &desc))) {
        printf("adapter: %ls (vendor 0x%04x, device 0x%04x, %llu MB VRAM)\n", desc.Description,
               desc.VendorId, desc.DeviceId, (unsigned long long)(desc.DedicatedVideoMemory >> 20));
    }
}

static int probe_d3d11(void) {
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    D3D_FEATURE_LEVEL level = 0;
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                   D3D11_SDK_VERSION, &device, &level, &context);
    if (FAILED(hr)) {
        printf("D3D11CreateDevice failed: 0x%08lx\n", (unsigned long)hr);
        return 1;
    }
    printf("D3D11 device created, feature level %u.%u\n", (level >> 12) & 0xf, (level >> 8) & 0xf);

    IDXGIDevice *dxgi = NULL;
    IDXGIAdapter *adapter = NULL;
    if (SUCCEEDED(ID3D11Device_QueryInterface(device, &IID_IDXGIDevice, (void **)&dxgi)) &&
        SUCCEEDED(IDXGIDevice_GetAdapter(dxgi, &adapter))) {
        print_adapter(adapter);
        IDXGIAdapter_Release(adapter);
    }
    if (dxgi) IDXGIDevice_Release(dxgi);
    ID3D11DeviceContext_Release(context);
    ID3D11Device_Release(device);
    return 0;
}

static int probe_d3d12(void) {
    HMODULE d3d12 = LoadLibraryA("d3d12.dll");
    if (!d3d12) {
        printf("d3d12.dll could not be loaded (error %lu)\n", GetLastError());
        return 1;
    }
    PFN_D3D12_CREATE_DEVICE create = (PFN_D3D12_CREATE_DEVICE)(void *)GetProcAddress(d3d12, "D3D12CreateDevice");
    ID3D12Device *device = NULL;
    HRESULT hr = create ? create(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&device) : E_NOINTERFACE;
    if (FAILED(hr)) {
        printf("D3D12CreateDevice failed: 0x%08lx\n", (unsigned long)hr);
        return 1;
    }
    printf("D3D12 device created\n");
    ID3D12Device_Release(device);
    return 0;
}

int probe_d3d8(void);

static int probe_d3d9(void) {
    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    if (!d3d) {
        printf("Direct3DCreate9 failed\n");
        return 1;
    }
    D3DADAPTER_IDENTIFIER9 id;
    if (SUCCEEDED(IDirect3D9_GetAdapterIdentifier(d3d, D3DADAPTER_DEFAULT, 0, &id))) {
        printf("adapter: %s (vendor 0x%04lx, device 0x%04lx)\n", id.Description, id.VendorId, id.DeviceId);
    }
    HWND window = CreateWindowA("STATIC", "d3dprobe", WS_OVERLAPPEDWINDOW, 0, 0, 320, 240, NULL, NULL, NULL, NULL);
    D3DPRESENT_PARAMETERS pp = {0};
    pp.Windowed = TRUE;
    pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.BackBufferFormat = D3DFMT_UNKNOWN;
    pp.hDeviceWindow = window;
    IDirect3DDevice9 *device = NULL;
    HRESULT hr = IDirect3D9_CreateDevice(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, window,
                                         D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &device);
    if (FAILED(hr)) {
        printf("IDirect3D9::CreateDevice failed: 0x%08lx\n", (unsigned long)hr);
        IDirect3D9_Release(d3d);
        return 1;
    }
    hr = IDirect3DDevice9_Clear(device, 0, NULL, D3DCLEAR_TARGET, D3DCOLOR_XRGB(0, 0, 255), 1.0f, 0);
    if (SUCCEEDED(hr)) hr = IDirect3DDevice9_Present(device, NULL, NULL, NULL, NULL);
    printf("D3D9 device created; clear+present %s\n", SUCCEEDED(hr) ? "ok" : "failed");
    IDirect3DDevice9_Release(device);
    IDirect3D9_Release(d3d);
    DestroyWindow(window);
    return SUCCEEDED(hr) ? 0 : 1;
}

static ID3D11Device *create_device(void) {
    ID3D11Device *device = NULL;
    D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT, NULL, 0,
                      D3D11_SDK_VERSION, &device, NULL, NULL);
    return device;
}

static int probe_shared(void) {
    ID3D11Device *a = create_device(), *b = create_device();
    if (!a || !b) { printf("D3D11CreateDevice failed\n"); return 1; }
    int failures = 0;
    UINT flags[] = {D3D11_RESOURCE_MISC_SHARED, D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX, 0};
    const char *names[] = {"MISC_SHARED", "MISC_SHARED_KEYEDMUTEX", "no shared flag"};
    for (int i = 0; i < 3; i++) {
        D3D11_TEXTURE2D_DESC desc = {256, 256, 1, 1, DXGI_FORMAT_B8G8R8A8_UNORM, {1, 0}, D3D11_USAGE_DEFAULT,
                                     D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET, 0, flags[i]};
        ID3D11Texture2D *texture = NULL;
        HRESULT hr = ID3D11Device_CreateTexture2D(a, &desc, NULL, &texture);
        if (FAILED(hr)) { printf("%-24s CreateTexture2D failed: 0x%08lx\n", names[i], (unsigned long)hr); failures++; continue; }
        IDXGIResource *resource = NULL;
        HANDLE handle = NULL;
        ID3D11Texture2D_QueryInterface(texture, &IID_IDXGIResource, (void **)&resource);
        hr = resource ? IDXGIResource_GetSharedHandle(resource, &handle) : E_NOINTERFACE;
        ID3D11Texture2D *opened = NULL;
        HRESULT open = handle ? ID3D11Device_OpenSharedResource(b, handle, &IID_ID3D11Texture2D, (void **)&opened) : E_HANDLE;
        printf("%-24s GetSharedHandle 0x%08lx handle %p, OpenSharedResource 0x%08lx\n", names[i],
               (unsigned long)hr, handle, (unsigned long)open);
        if (flags[i] && (FAILED(hr) || !handle || FAILED(open))) failures++;
        if (opened) ID3D11Texture2D_Release(opened);
        if (resource) IDXGIResource_Release(resource);
        ID3D11Texture2D_Release(texture);
    }
    ID3D11Device_Release(a);
    ID3D11Device_Release(b);
    return failures ? 1 : 0;
}

static HRESULT wait_data(ID3D11DeviceContext *context, ID3D11Query *query, void *data, UINT size) {
    HRESULT hr = S_FALSE;
    for (int i = 0; i < 2000 && hr == S_FALSE; i++) {
        hr = ID3D11DeviceContext_GetData(context, (ID3D11Asynchronous *)query, data, size, 0);
        if (hr == S_FALSE) Sleep(1);
    }
    return hr;
}

static int probe_timestamp(void) {
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    if (FAILED(D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION,
                                 &device, NULL, &context))) { printf("D3D11CreateDevice failed\n"); return 1; }
    D3D11_QUERY_DESC disjoint_desc = {D3D11_QUERY_TIMESTAMP_DISJOINT, 0}, ts_desc = {D3D11_QUERY_TIMESTAMP, 0};
    ID3D11Query *disjoint = NULL, *begin = NULL, *end = NULL;
    HRESULT hr = ID3D11Device_CreateQuery(device, &disjoint_desc, &disjoint);
    printf("CreateQuery(TIMESTAMP_DISJOINT) 0x%08lx\n", (unsigned long)hr);
    hr = ID3D11Device_CreateQuery(device, &ts_desc, &begin);
    printf("CreateQuery(TIMESTAMP)          0x%08lx\n", (unsigned long)hr);
    ID3D11Device_CreateQuery(device, &ts_desc, &end);
    if (!disjoint || !begin || !end) return 1;

    D3D11_TEXTURE2D_DESC desc = {256, 256, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM, {1, 0}, D3D11_USAGE_DEFAULT,
                                 D3D11_BIND_RENDER_TARGET, 0, 0};
    ID3D11Texture2D *texture = NULL;
    ID3D11RenderTargetView *rtv = NULL;
    ID3D11Device_CreateTexture2D(device, &desc, NULL, &texture);
    ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)texture, NULL, &rtv);
    float color[4] = {1, 0, 0, 1};

    int failures = 0;
    for (int frame = 0; frame < 3; frame++) {
        ID3D11DeviceContext_Begin(context, (ID3D11Asynchronous *)disjoint);
        ID3D11DeviceContext_End(context, (ID3D11Asynchronous *)begin);
        for (int i = 0; i < 100; i++) ID3D11DeviceContext_ClearRenderTargetView(context, rtv, color);
        ID3D11DeviceContext_End(context, (ID3D11Asynchronous *)end);
        ID3D11DeviceContext_End(context, (ID3D11Asynchronous *)disjoint);
        ID3D11DeviceContext_Flush(context);

        D3D11_QUERY_DATA_TIMESTAMP_DISJOINT dj = {0};
        UINT64 t0 = 0, t1 = 0;
        HRESULT h0 = wait_data(context, disjoint, &dj, sizeof(dj));
        HRESULT h1 = wait_data(context, begin, &t0, sizeof(t0));
        HRESULT h2 = wait_data(context, end, &t1, sizeof(t1));
        printf("frame %d: disjoint 0x%08lx freq %llu disjoint=%d; begin 0x%08lx %llu; end 0x%08lx %llu; delta %lld\n",
               frame, (unsigned long)h0, (unsigned long long)dj.Frequency, dj.Disjoint, (unsigned long)h1,
               (unsigned long long)t0, (unsigned long)h2, (unsigned long long)t1, (long long)(t1 - t0));
        if (h0 != S_OK || h1 != S_OK || h2 != S_OK || !dj.Frequency || dj.Disjoint || t1 < t0) failures++;
    }
    return failures ? 1 : 0;
}

static int all_done(const int *a, const int *b, int n) {
    for (int i = 0; i < n; i++) if (!a[i] || !b[i]) return 0;
    return 1;
}

static int probe_queryorder(void) {
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    if (FAILED(D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION,
                                 &device, NULL, &context))) { printf("D3D11CreateDevice failed\n"); return 1; }
    D3D11_QUERY_DESC dj_desc = {D3D11_QUERY_TIMESTAMP_DISJOINT, 0}, ts_desc = {D3D11_QUERY_TIMESTAMP, 0};
    D3D11_TEXTURE2D_DESC desc = {256, 256, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM, {1, 0}, D3D11_USAGE_DEFAULT,
                                 D3D11_BIND_RENDER_TARGET, 0, 0};
    ID3D11Texture2D *texture = NULL;
    ID3D11RenderTargetView *rtv = NULL;
    ID3D11Device_CreateTexture2D(device, &desc, NULL, &texture);
    ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)texture, NULL, &rtv);
    float color[4] = {0, 1, 0, 1};
    enum { frames = 8 };
    ID3D11Query *dj[frames], *ts[frames];
    int ts_done[frames] = {0}, dj_done[frames] = {0}, early = 0, ts_first_ready = -1, dj_first_ready = -1;
    for (int f = 0; f < frames; f++) {
        ID3D11Device_CreateQuery(device, &dj_desc, &dj[f]);
        ID3D11Device_CreateQuery(device, &ts_desc, &ts[f]);
    }
    /* Issue one "frame" per iteration, then poll every outstanding query once without flushing. */
    for (int iter = 0; iter < 400 && !(iter > frames && all_done(ts_done, dj_done, frames)); iter++) {
        if (iter < frames) {
            ID3D11DeviceContext_Begin(context, (ID3D11Asynchronous *)dj[iter]);
            for (int i = 0; i < 50; i++) ID3D11DeviceContext_ClearRenderTargetView(context, rtv, color);
            ID3D11DeviceContext_End(context, (ID3D11Asynchronous *)ts[iter]);
            ID3D11DeviceContext_End(context, (ID3D11Asynchronous *)dj[iter]);
            ID3D11DeviceContext_Flush(context);
        }
        for (int f = 0; f < frames && f <= iter; f++) {
            UINT64 t;
            D3D11_QUERY_DATA_TIMESTAMP_DISJOINT d;
            /* Disjoint first, so a timestamp only counts as early if its disjoint query still
             * wasn't ready when polled just before it. */
            if (!dj_done[f] && ID3D11DeviceContext_GetData(context, (ID3D11Asynchronous *)dj[f], &d, sizeof(d),
                                                           D3D11_ASYNC_GETDATA_DONOTFLUSH) == S_OK) {
                dj_done[f] = 1;
                if (dj_first_ready < 0) dj_first_ready = iter;
            }
            if (!ts_done[f] && ID3D11DeviceContext_GetData(context, (ID3D11Asynchronous *)ts[f], &t, sizeof(t),
                                                           D3D11_ASYNC_GETDATA_DONOTFLUSH) == S_OK) {
                ts_done[f] = 1;
                if (ts_first_ready < 0) ts_first_ready = iter;
                if (!dj_done[f]) early++;
            }
        }
        Sleep(1);
    }
    int ts_count = 0, dj_count = 0;
    for (int f = 0; f < frames; f++) { ts_count += ts_done[f]; dj_count += dj_done[f]; }
    printf("timestamps ready %d/%d (first at poll %d), disjoint ready %d/%d (first at poll %d)\n",
           ts_count, frames, ts_first_ready, dj_count, frames, dj_first_ready);
    printf("timestamps ready while their disjoint query was not: %d\n", early);
    return early || ts_count < frames || dj_count < frames ? 1 : 0;
}

/* Mirrors FD3D11DynamicRHI's calibration in UE 5 (Satisfactory): up to 10 attempts. */
static int probe_calibrate(void) {
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    if (FAILED(D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION,
                                 &device, NULL, &context))) { printf("D3D11CreateDevice failed\n"); return 1; }
    D3D11_QUERY_DESC dj_desc = {D3D11_QUERY_TIMESTAMP_DISJOINT, 0}, ts_desc = {D3D11_QUERY_TIMESTAMP, 0},
                     ev_desc = {D3D11_QUERY_EVENT, 0};
    ID3D11Query *dj, *ts, *idle, *ev;
    ID3D11Device_CreateQuery(device, &dj_desc, &dj);
    ID3D11Device_CreateQuery(device, &ts_desc, &ts);
    ID3D11Device_CreateQuery(device, &ev_desc, &idle);
    ID3D11Device_CreateQuery(device, &ev_desc, &ev);
    BOOL done = FALSE;
    ID3D11DeviceContext_End(context, (ID3D11Asynchronous *)idle);
    ID3D11DeviceContext_Flush(context);
    while (ID3D11DeviceContext_GetData(context, (ID3D11Asynchronous *)idle, &done, sizeof(done), 0) != S_OK || !done) Sleep(0);
    int ok = 0;
    for (int attempt = 0; attempt < 10; attempt++) {
        ID3D11DeviceContext_Begin(context, (ID3D11Asynchronous *)dj);
        ID3D11DeviceContext_End(context, (ID3D11Asynchronous *)ts);
        ID3D11DeviceContext_End(context, (ID3D11Asynchronous *)dj);
        ID3D11DeviceContext_End(context, (ID3D11Asynchronous *)ev);
        ID3D11DeviceContext_Flush(context);
        done = FALSE;
        while (ID3D11DeviceContext_GetData(context, (ID3D11Asynchronous *)ev, &done, sizeof(done), 0) != S_OK || !done) {}
        D3D11_QUERY_DATA_TIMESTAMP_DISJOINT d = {0};
        UINT64 t = 0;
        HRESULT hd = ID3D11DeviceContext_GetData(context, (ID3D11Asynchronous *)dj, &d, sizeof(d), 0);
        HRESULT ht = ID3D11DeviceContext_GetData(context, (ID3D11Asynchronous *)ts, &t, sizeof(t), 0);
        printf("attempt %d: after the event signalled, disjoint 0x%08lx (disjoint=%d freq %llu), timestamp 0x%08lx (%llu)\n",
               attempt, (unsigned long)hd, d.Disjoint, (unsigned long long)d.Frequency, (unsigned long)ht,
               (unsigned long long)t);
        if (hd == S_OK && !d.Disjoint && ht == S_OK && t) { ok = 1; break; }
    }
    printf(ok ? "calibration OK\n" : "calibration FAILED (Unreal 5 asserts: unset TOptional<FTimestampCalibration>)\n");
    return ok ? 0 : 1;
}

static LRESULT CALLBACK crossproc_wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    return DefWindowProcA(hwnd, msg, wp, lp);
}

/* Child: present red into another process's window for a few seconds. */
static int crossproc_child(HWND hwnd) {
    DXGI_SWAP_CHAIN_DESC desc = {0};
    desc.BufferDesc.Width = 0; desc.BufferDesc.Height = 0;
    desc.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.OutputWindow = hwnd;
    desc.Windowed = TRUE;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    IDXGISwapChain *swapchain = NULL;
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION,
                                               &desc, &swapchain, &device, NULL, &context);
    printf("child: D3D11CreateDeviceAndSwapChain on hwnd %p: 0x%08lx\n", hwnd, (unsigned long)hr);
    if (FAILED(hr)) return 1;
    ID3D11Texture2D *back = NULL;
    ID3D11RenderTargetView *rtv = NULL;
    IDXGISwapChain_GetBuffer(swapchain, 0, &IID_ID3D11Texture2D, (void **)&back);
    ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)back, NULL, &rtv);
    float red[4] = {1, 0, 0, 1};
    for (int i = 0; i < 300; i++) {
        ID3D11DeviceContext_ClearRenderTargetView(context, rtv, red);
        IDXGISwapChain_Present(swapchain, 1, 0);
        Sleep(16);
    }
    return 0;
}

/* Parent: own a window (with a child window, as Chromium does), run the child against the child
 * window, and keep pumping messages meanwhile. */
static int probe_crossproc(BOOL inset) {
    WNDCLASSA wc = {0};
    wc.lpfnWndProc = crossproc_wndproc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "d3dprobe_crossproc";
    wc.hbrBackground = (HBRUSH)GetStockObject(inset ? GRAY_BRUSH : BLACK_BRUSH);
    RegisterClassA(&wc);
    HWND top = CreateWindowA("d3dprobe_crossproc", "d3dprobe crossproc", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                             100, 100, 640, 400, NULL, NULL, wc.hInstance, NULL);
    RECT rc;
    GetClientRect(top, &rc);
    HWND child = inset ? CreateWindowA("d3dprobe_crossproc", NULL, WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | WS_CLIPCHILDREN,
                                       80, 60, 300, 200, top, NULL, wc.hInstance, NULL)
                       : CreateWindowA("d3dprobe_crossproc", NULL, WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | WS_CLIPCHILDREN,
                                       0, 0, rc.right, rc.bottom, top, NULL, wc.hInstance, NULL);
    char exe[MAX_PATH], cmd[MAX_PATH + 64];
    GetModuleFileNameA(NULL, exe, MAX_PATH);
    snprintf(cmd, sizeof(cmd), "\"%s\" crossproc-child %p", exe, (void *)child);
    STARTUPINFOA si = {sizeof(si)};
    PROCESS_INFORMATION pi;
    if (!CreateProcessA(NULL, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) { printf("CreateProcess failed\n"); return 1; }
    for (;;) {
        MSG msg;
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
        if (WaitForSingleObject(pi.hProcess, 10) == WAIT_OBJECT_0) break;
    }
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    printf("child exited with %lu\n", code);
    return (int)code;
}

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "11";
    if (strcmp(mode, "crossproc-child") == 0 && argc > 2) {
        void *hwnd = NULL;
        sscanf(argv[2], "%p", &hwnd);
        return crossproc_child((HWND)hwnd);
    }
    int result = strcmp(mode, "12") == 0 ? probe_d3d12() : strcmp(mode, "9") == 0 ? probe_d3d9()
               : strcmp(mode, "8") == 0 ? probe_d3d8()
               : strcmp(mode, "shared") == 0 ? probe_shared()
               : strcmp(mode, "timestamp") == 0 ? probe_timestamp()
               : strcmp(mode, "queryorder") == 0 ? probe_queryorder()
               : strcmp(mode, "calibrate") == 0 ? probe_calibrate()
               : strcmp(mode, "crossproc") == 0 ? probe_crossproc(argc > 2 && strcmp(argv[2], "inset") == 0)
               : probe_d3d11();
    printf("modules:\n");
    print_module("d3d11.dll");
    print_module("d3d12.dll");
    print_module("d3d9.dll");
    print_module("d3d8.dll");
    print_module("dxgi.dll");
    print_module("winemetal.dll");
    print_module("wined3d.dll");
    return result;
}
